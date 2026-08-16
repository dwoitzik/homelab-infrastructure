# Disaster Recovery

This is the runbook for rebuilding this homelab from nothing — bare Proxmox host up
through every app being reachable again. It assumes total loss of the `mini` host (disk,
VMs, everything). For partial losses (one VM, one PVC, one secret), skip to the relevant
tier or to [Per-Service Restore](#per-service-restore) below.

**Design philosophy** (see `docs/k3s-architecture.md`): this homelab targets *recovery*,
not high availability. `mini` is a single point of failure by hardware constraint —
there's no second host to fail over to. Every tier below exists so that a full rebuild is
a *documented, repeatable procedure*, not an improvisation.

**RTO/RPO targets:**

| Scope | RPO | RTO (realistic) |
|---|---|---|
| Full host loss (this runbook, tiers 1-6) | 24h (last PBS/Velero backup) | 4-8h (mostly waiting on restores + manual steps below) |
| Single PVC / single app | 24h (last Velero backup) | 15-30 min |
| Single VM/LXC (not k3s) | 24h (last PBS backup) | 15-30 min (PBS restore in Proxmox UI) |
| Network config (MikroTik) | 0 (git is the source of truth) | Minutes, IF the router itself survives — see Tier 0 |

---

## Tier 0 — Network (MikroTik RB5009)

The router is physically separate from `mini` and normally survives a host-loss event
untouched. Skip this tier unless the router itself is also gone.

If the router needs to be rebuilt from scratch:

1. Factory-reset the RB5009, set a temporary admin password, get it reachable.
2. There is **no native MikroTik config export** in this workflow — the Terraform API
   user lacks `/system backup` permission (see `docs/OPERATIONS.md`, "Pending" section).
   Recovery is via Terraform state + manual recreation of the API user, in that order:
   - Manually create the Terraform API user/password matching
     `terraform/stacks/network/provider.tf`.
   - `cd terraform/stacks/network && terraform init && terraform plan` — review carefully,
     then apply via the normal Atlantis PR flow once Atlantis itself is reachable. Atlantis
     runs on its own dedicated LXC (`ct-srv-atlantis-01`), independent of k3s — if the
     router is gone but the LXC survives, Atlantis is usable as soon as network config is
     back. If both the router and the LXC are gone, restore the LXC via Tier 1 first (or
     recreate it from `terraform/stacks/proxmox/`), then hand the rest back to Atlantis.
3. Verify VLANs 10/20/30/40/100 and the default-drop firewall chains are back before
   reconnecting anything else — see `docs/vlan-segmentation.md`.

---

## Tier 1 — Proxmox Host

1. Reinstall Proxmox VE on `mini` (fresh ISO install). Recreate the `local-lvm` (LVM-thin,
   VG `pve`) layout on the 512GB NVMe — see `docs/compute-nodes.md` for the disk layout
   this depends on (512GB SSD only for anything stateful; never the USB HDD or scratch
   stick). This was `rpool` (ZFS) before the 2026-08-13 migration; ZFS is no longer used
   for boot/VM-image storage on this host, only for the `archive` pool on the USB HDD.
2. Restore the OIDC realm config (Authelia SSO for the Proxmox web UI) — this is
   API-automatable, not a manual click-through:

   ```bash
   pvesh set /access/domains/authelia --client-key <value>   # see docs/secrets-inventory.md
   ```

   Until Authelia itself is back up (Tier 3+), log in with local `root@pam` — this
   fallback always exists by design, there is no lockout risk.
3. Re-run the Terraform `proxmox` stack (`terraform/stacks/proxmox/`) via PR + Atlantis to
   recreate the VM/LXC definitions — this does NOT restore data, only the resource
   shells (disks, network, CPU/RAM, GPU passthrough for `ct_srv_ai_01`).
4. Restore each VM/LXC's actual disk contents from PBS:

   ```bash
   # In the Proxmox web UI: Datacenter > pbs-storage > <vmid> > Backups > Restore
   # or via CLI on the Proxmox host itself (pve-mgmt-01, 10.0.10.10):
   pct restore <new-or-same-vmid> local-pbs:backup/ct/<vmid>/<snapshot> --storage local-zfs
   ```

   **Verified live 2026-07-06** (real test, not a dry run): restored `ct-srv-atlantis-01`'s
   (vmid 204) most recent PBS snapshot to a scratch vmid (999) alongside the still-running
   original, booted it, and confirmed it came up clean (`systemctl is-system-running` →
   `running`) with its Docker stack auto-starting from the restored compose file and real
   data intact. Test container destroyed immediately after. **Gotcha found doing this**:
   a PBS restore recreates the container with the *exact same* static IP and MAC address
   as the original — starting it while the original is still running causes an IP/MAC
   conflict on the live network. If restoring alongside a still-live original (as opposed
   to a genuine full-loss recovery where the original is gone), change the restored
   copy's `net0` to `link_down=1` (or a different IP/MAC) before starting it, e.g.:
   `pct set <new-vmid> -net0 name=eth0,bridge=vmbr0,tag=<vlan>,link_down=1`.

   If the local 2TB USB HDD (`/mnt/pbs-storage`) is also gone, there is currently
   **no working offsite fallback for this** — the Google Drive sync (`docs/backup-strategy.md`
   Stage 3) is deliberately disabled (insufficient Drive storage), and even when it
   briefly ran, it never got far enough for a real PBS datastore worth restoring from
   (Google's API throttling on PBS's many-small-file format made the initial sync
   impractical). **This means total loss of both `mini`'s ZFS pool and the USB HDD
   simultaneously is currently unrecoverable at the VM/LXC layer** — only k3s workloads
   (Velero → Garage S3, itself also in-cluster and subject to the same gap described in
   Tier 5 below) would have any path back, and only if Garage's own data survived. This
   is the single biggest real gap in this recovery plan as written; revisit once an
   offsite backup target is actually working end-to-end.
5. Backup job coverage uses `all: 1` (every VM/CT, including all 3 k3s VMs and the NFS LXC)
   — confirm the restored job still does after rebuild; this was missing coverage
   historically and is worth re-verifying after any change to the job.
6. `/etc/vzdump.conf` carries hand-set `bwlimit: 51200` and `ionice: 7` (added
   2026-07-09, load/thermal-smoothing for the 03:00 job — `node_load1` was spiking to
   80 and correlated with recurring `ProxmoxHostHighTemp` firings). This file has no
   Terraform equivalent (no provider resource models these global vzdump defaults) and
   will **not** survive a fresh Proxmox install — re-add both lines by hand after
   rebuild, before the first scheduled backup runs, or the load/thermal spike returns
   silently. Tracked internally as a known hand-config gap alongside the rest of this
   host's un-managed settings (storage pools, datacenter config).

---

## Tier 2 — k3s Cluster Bootstrap

Once the 3 VMs (`vm-srv-k3s-11/12/13`) exist and are reachable (either freshly restored
from PBS with k3s already installed, or freshly created and needing k3s from scratch):

**If restored from PBS:** k3s starts itself via systemd; just confirm node health:

```bash
ssh root@10.0.20.11 'k3s kubectl get nodes -o wide'
```

**If building from scratch** (e.g. recreated VMs with no k3s installed):

```bash
cd ansible/k3s-cluster
ansible-playbook -i inventory.yml site.yml
```

`inventory.yml` must reflect the **current, corrected topology**: `vm-srv-k3s-11` alone
in `k3s_server`/`server` group, `-12` and `-13` in `k3s_agent`/`agent` only. **Do not**
use `inventory-ha.yml` or any config that puts all three in the server group — that
3-way embedded-etcd design is what froze the host previously (see `docs/k3s-architecture.md`
§1). Confirm `on_boot = true` is set for all three in
`terraform/stacks/proxmox/vm.tf` so they survive the next host reboot automatically.

After the cluster is up, re-apply the Keepalived VIP if needed:

```bash
ansible-playbook ansible/k3s-vip.yml
```

Known caveat: the VIP's failover priority list still includes k3s-12/13 from the old
design even though they don't run the API server — if `k3s-11` is down, go straight to
`10.0.20.11` rather than trusting the VIP (`10.0.20.10`) to land somewhere useful.

---

## Tier 3 — ArgoCD Bootstrap

ArgoCD's own installation is **not currently in this repo** (a known gap — it's a one-time
manual step, not GitOps-managed, since ArgoCD has to exist before it can manage anything
via GitOps):

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd wait --for=condition=available deploy/argocd-server --timeout=300s
```

Then apply this repo's ArgoCD config and bootstrap resources, in order:

```bash
# 1. Config (RBAC, repo settings) before anything else
kubectl apply -f kubernetes/system/argocd/argocd-cm.yml
kubectl apply -f kubernetes/system/argocd/argocd-rbac-cm.yml
kubectl apply -f kubernetes/system/argocd/argocd-cmd-params-cm.yml
kubectl -n argocd rollout restart deploy/argocd-server deploy/argocd-repo-server

# 2. The ApplicationSet — this alone brings up every app in kubernetes/apps/*
kubectl apply -f kubernetes/system/argocd/apps-applicationset.yaml

# 3. Manual system Applications — apply every Application manifest under kubernetes/system/*
#    (vault, external-secrets, velero, traefik, cert-manager, monitoring, postgres, kyverno, redis, etc.)
find kubernetes/system -maxdepth 2 -name '*application*.yml' -exec kubectl apply -f {} \;
```

ArgoCD will start reconciling everything from `main` immediately — including secrets via
ExternalSecrets, which will fail until Vault is unsealed (Tier 4). This is expected; pods
referencing not-yet-existing secrets will sit in `ContainerCreating`/`Pending` until then.
Authelia and `postgres-paperless` specifically have a `wait-for-vault-secret` initContainer
for exactly this reason — they'll wait quietly rather than crash-loop.

---

## Tier 4 — Vault Init, Unseal, and ExternalSecrets

This is the most failure-prone tier — there's a real chicken/egg between Vault, its
unseal keys, and the secret that lets ExternalSecrets talk to it. Follow in order (this
sequence is also documented inline in `kubernetes/system/external-secrets/cluster-secret-store.yml`):

```bash
# 1. Wait for the vault-0 pod to exist (synced by ArgoCD in Tier 3)
kubectl -n vault wait --for=condition=ready pod/vault-0 --timeout=300s

# 2. Initialize Vault — ONLY if this is a genuinely new Vault (no existing raft data).
#    If raft data survived (restored PVC), skip straight to step 4 with the EXISTING keys.
kubectl exec -n vault vault-0 -- vault operator init -key-shares=3 -key-threshold=2
#    => capture Unseal Key 1, 2, 3 and the Initial Root Token. These do not exist anywhere
#       else until you save them — write them into ansible/group_vars/all/vault.yml
#       (vault_unseal_key_1/2/3, vault_root_token) via `ansible-vault edit`, immediately.

# 3. Unseal (2 of 3 keys)
kubectl exec -n vault vault-0 -- vault operator unseal <key_1>
kubectl exec -n vault vault-0 -- vault operator unseal <key_2>

# 4. Re-create the k8s Secret the vault-unseal sidecar reads (it cannot be an
#    ExternalSecret itself — Vault isn't reachable yet to source it from)
kubectl create secret generic vault-unseal-keys -n vault \
  --from-literal=key1=<key_1> --from-literal=key2=<key_2>
#    or: ansible-playbook ansible/vault-unseal-secret.yml   (if the playbook sources
#    from the vault file directly — check ansible/ for the current script name)

# 5. Log in with the root token and create the token ESO uses to authenticate to Vault
kubectl exec -n vault vault-0 -- vault login <root_token>
kubectl create secret generic vault-token -n external-secrets --from-literal=token=<root_token>

# 6. Confirm the ClusterSecretStore goes healthy, then ExternalSecrets start syncing
kubectl get clustersecretstore vault -o jsonpath='{.status.conditions}'
kubectl get externalsecrets -A
```

If this is a **new Vault with no surviving data** (worst case — raft storage itself was
lost), every secret previously stored under `secret/<app>/...` is gone and must be
re-populated from `ansible/group_vars/all/vault.yml` (the Ansible Vault file is the
durable source for anything that was ever manually seeded into Vault — see
`docs/secrets-inventory.md` for the full path-by-path inventory) before ExternalSecrets
will have anything to sync.

**Note:** Vault's own raft storage PVC is on `storageClassName: nfs-client`
(`kubernetes/system/vault/application.yml`) — a known, accepted risk. Raft's own
consensus tolerates NFS better than a plain SQLite/BoltDB file would (see the
Garage/SQLite gotcha in Per-Service Restore below), but it's not proven safe long-term.
If Vault's data is ever found corrupted on NFS, treat it the same as that Garage
incident: stop the pod, attempt `vault operator raft snapshot`, or fall back to full
re-init per this tier.

---

## Tier 5 — Velero Restore

Once Velero itself is up (synced in Tier 3, its own state is stateless — backups live in
Garage S3, which is itself an app restored as part of the ApplicationSet):

```bash
# Garage must be healthy and reachable before Velero can read its own backup bucket —
# if Garage's data PVC was lost, Garage starts empty and Velero has nothing to restore
# from until the offsite copy (Cloudflare R2, not yet active) is wired up instead.
velero backup get
velero restore create --from-backup <latest-daily-backup-name>
```

`defaultVolumesToFsBackup: true` is set on the `daily-backup` Schedule
(`kubernetes/system/velero/`), so this restores PVC *contents* (via Kopia), not just k8s
object manifests — including `nfs-client`-backed PVCs, which have no CSI snapshotter.

If you only need one namespace or app back:

```bash
velero restore create --from-backup <name> --include-namespaces apps
velero restore create --from-backup <name> --selector app=<label>
```

**Known gap:** Velero's only backend right now is Garage S3, which is in-cluster — if the
whole cluster (not just one VM) was lost, Garage's backup bucket is gone too, and this
tier has nothing to restore from. The Cloudflare R2 offsite copy (`daily-offsite`
Schedule) is configured but deliberately not turned on yet (see `docs/backup-strategy.md`).
Until it is, the **real** worst-case recovery path is PBS VM-level restore (Tier 1) of the
k3s VMs themselves, which carries Garage's PVC data along with the VM disk — not Velero.

---

## Per-Service Restore

Most apps need nothing beyond Tiers 1-5 (ArgoCD redeploys the manifest, Velero/PBS
restores the data, ExternalSecrets re-syncs the secret). The exceptions:

| App | Storage class | Gotcha |
|---|---|---|
| Garage (`garage-meta`) | `local-path` | Node-pinned. If the bound node is gone, restore the PVC from Velero fs-backup to a fresh PV on whichever node it (re)binds to. Technique: spin up a temporary `busybox` pod mounting the empty new PVC, `kubectl cp` or a Velero fs-restore populates it, then let Garage's own Deployment take over once the data's in place. |
| Headscale, Vaultwarden, Gitea, Mealie, Open WebUI, paperless-ai, Home Assistant | `local-path` | Same node-pinning caveat as Garage. All were migrated off `nfs-client` specifically because SQLite/BoltDB don't tolerate NFS locking — do **not** move them back. |
| Authelia (`postgres-authelia`, CNPG) | `nfs-client` (PVC) + Garage S3 (barman WAL archive, `kubernetes/system/postgres/cluster.yml`) | CNPG's `bootstrap.initdb.secret` only runs once at cluster creation — changing the `postgres-authelia-user` k8s Secret post-bootstrap does **not** change the live Postgres password. To rotate or restore with a known password: `kubectl exec -n database postgres-authelia-1 -c postgres -- psql -U postgres -c "ALTER USER authelia WITH PASSWORD '...'"`. Barman is configured for continuous WAL archiving, and a daily `ScheduledBackup` (`0 2 * * *`, `kubernetes/system/postgres/scheduled-backup.yml`) now produces a base backup to restore from via barman; the PVC restore (Tier 5) or a manual `pg_dump`/`psql` round-trip as documented inline in `cluster.yml` remain available as fallbacks. |
| Authelia OIDC config (`kubernetes/apps/authelia/configmap.yml`) | — | Client secrets are argon2id hashes of the plaintext stored in each downstream service (Proxmox, PBS, ArgoCD, Grafana). If Vault is rebuilt from scratch (Tier 4 worst case), these hashes survive in git, but the matching plaintext secrets in Proxmox/PBS/ArgoCD/Grafana's own OIDC client configs do not — re-run the relevant `pvesh`/`proxmox-backup-manager`/`kubectl patch` commands from `docs/secrets-inventory.md` to re-align them. |
| Nextcloud | `nfs-client` (incl. its own `postgres:16-alpine` StatefulSet, not CNPG) | Plain Postgres, not CNPG — no barman backup. Recovery relies entirely on Velero PVC restore (Tier 5) or PBS VM-level restore (Tier 1) of the NFS LXC. |
| Immich (`immich-db` PVC) | `nfs-client` (postgres + library) | **Immich v2.7.5** uses `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` (PG14, VectorChord). The `immich-db` PVC holds the postgres datadir; `immich-library` holds the photo/video files. Both are on `nfs-client` and covered by Velero fs-backup. **Critical:** after a PVC restore, confirm the postgres container starts clean — if there are `PGDATA` version mismatch errors (e.g. data directory was written by a different PG version), a fresh-DB recovery is the only path: scale down all Immich pods, wipe `/data/pgdata` via a busybox pod, and scale back up (ArgoCD/postgres will reinitialize). Users must re-create their accounts and re-upload photos in that scenario — there is no incremental migration path available from a cold-start PVC failure with version mismatch. Photos themselves survive on `immich-library` PVC even if the database is wiped. |
| Immich (Cloudflare Tunnel) | — | `photos.woitzik.dev` routes through Cloudflare Tunnel (tunnel ID `1f2e0f78-214b-4f59-881d-37e22625ae6e`). If the `cloudflared` Deployment in the `apps` namespace is down, or if the Cloudflare API token in Ansible Vault is rotated without updating `atlantis-secrets`, the tunnel will be disconnected and external access will stop. Internal access via `*.woitzik.dev` wildcard → Traefik still works for VPN-connected clients. The Cloudflare DNS CNAME record (`photos → <tunnel>.cfargotunnel.com`) was created via Terraform in the `terraform/stacks/cloudflare/` stack and is in remote TF state. |
| Jellyfin `media` PVC | direct NFS mount (not nfs-client provisioner) | **Not covered by Velero at all.** Recovery depends entirely on the NFS LXC's own PBS backup (Tier 1) — confirm `ct_srv_nfs_01` (vmid 220) is actually in the PBS job's scope (it is, per `all: 1` in the vzdump job — this was missing coverage at one point, worth re-confirming after any PBS job edit). |
| `ct-srv-nfs-01` (NFS LXC) | — | Backs nearly every `nfs-client` PVC cluster-wide. **Never run concurrent backup/restore reads across multiple apps' directories against it at once** — it OOM'd at 512MB RAM under exactly that load on 2026-06-23 (now provisioned with 2GB + 1GB swap). Restore/copy one app's data at a time. |
| MegaStar7 / Cobblemon, other Minecraft servers | Proxmox LXC (`ct_dmz_games_01`), not k8s | Restore via Tier 1 (PBS) only — entirely outside ArgoCD/Velero's scope. Memory was raised 12→16GB (+2GB swap) after repeated OOM-driven timeouts; if recreating from Terraform instead of restoring from a PBS snapshot, confirm `terraform/stacks/proxmox/lxc.tf`'s `ct_dmz_games_01` block still reflects that before going live. |

---

## Verification Checklist

After working through the tiers above, confirm before declaring recovery complete:

- [ ] `kubectl get nodes` — all 3 k3s nodes `Ready`, correct roles (1 control-plane, 2 workers)
- [ ] `kubectl get applications -n argocd` — all `Synced`/`Healthy`
- [ ] `kubectl get externalsecrets -A` — all `SecretSynced`, none stuck on stale Vault-sealed errors
- [ ] `kubectl exec -n vault vault-0 -- vault status` — `Sealed: false`
- [ ] `kubectl get pods -A | grep -v Running` — nothing unexpectedly crash-looping or pending
- [ ] Spot-check 2-3 apps end-to-end through their real URL (`https://*.woitzik.dev`), through Authelia login
- [ ] `https://photos.woitzik.dev` reachable from outside the VPN (Cloudflare Tunnel path) — Immich login works and photo upload succeeds
- [ ] `velero backup get` and PBS job history both show a *new* successful run post-recovery, not just stale pre-incident entries
- [ ] Update this doc with anything that didn't go as written here — this runbook is only as good as its last real test
