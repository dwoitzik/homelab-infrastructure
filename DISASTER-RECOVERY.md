# Disaster Recovery Runbook

Bare metal to running cluster, assuming nothing survives but: PBS backups, the Garage
S3 bucket contents (if the host running Garage is also gone, this assumes the archive
disk itself survives), and this git repo. Written from the actual 2026-08-13 recovery —
every step here was really executed, not theorized. See `docs/HARDWARE.md` for why
several steps are the way they are.

## 0. Before you start

Read `HARDWARE.md` first. The single most important constraint: **the boot NVMe is
DRAM-less** — don't restore/stage large data onto it if the HDD-backed `media`/`archive`
pool is available instead.

## 1. Host foundation

1. Confirm Proxmox boots and `pvesh` responds. Check `proxmox-boot-tool status` —
   missing UUID tracking is a real bug this recovery hit, not paranoia.
2. Confirm storage: `local-lvm` (LVM-thin) for boot/VM-image, `media`/`archive` (ZFS,
   HDD) for bulk/staging. If ZFS shows up on the boot path, that's drift — see
   `HARDWARE.md` for why it shouldn't be there.
3. Confirm SSH access works both to the host and from wherever this repo is checked out.
   A pmxcfs/`authorized_keys` symlink dependency caused a real lockout during the
   2026-08-13 recovery — `authorized_keys2` is the workaround if `authorized_keys` isn't
   being read correctly.

## 2. Preserve Tier-1 data before touching anything destructive

If VMs/LXCs need restoring from PBS to inspect their data, **restore to scratch VMIDs on
the HDD-backed `media` storage, not NVMe, and do not boot them.** Set `onboot=0`
explicitly and immediately — a real incident during this recovery had scratch VMs
auto-start after a host reboot and IP-conflict with the freshly-provisioned production
VMs, causing over an hour of misdiagnosed "flakiness."

Mount VM disks read-only (`qemu-nbd -r -c`, `mount -o ro,noload` to skip journal replay
without writing) to extract data. Copy extracted data to the `media`/`archive` pool, not
the NVMe.

## 3. Rebuild the k3s cluster

1. Fresh VMs (or LXCs, per whatever the current `terraform/stacks/proxmox/` declares),
   cloned from the template — verify `ciupgrade=0` on the template's cloud-init config
   (an unpinned upgrade caused a real version-drift bug during this recovery).
2. Install k3s via `ansible/k3s-cluster/` — **pin the version explicitly**
   (`INSTALL_K3S_VERSION`) for every node, server and agents alike. The install script
   defaults to latest, which caused a real version mismatch between server and an agent
   during this recovery.
3. Secrets in the datastore are encrypted (ADR-077). When the server comes back from a
   restored `state.db` (PBS restore of VM 211 or a copied database), the key file
   `/var/lib/rancher/k3s/server/cred/encryption-config.json` must be in place before k3s
   starts: it is inside the VM 211 backup, and its offline copy is
   `vault_k3s_encryption_config` in Ansible Vault (`ansible-playbook site.yml --limit
   vm-srv-k3s-11 --tags k3s_secrets_encryption` writes it when missing). A fresh cluster
   with no restored datastore needs nothing: k3s generates a new key.
4. Confirm the datastore is actually SQLite (single server, no `cluster-init`), not
   etcd — `kubectl` behaves the same either way, but `docs/decisions/ADR-015` explains
   why this matters for the hardware.
5. Apply CNI/MetalLB/Traefik/cert-manager, then bootstrap ArgoCD.
6. **Do not bulk-apply `kubernetes/system/argocd/apps-applicationset.yml` or
   `system-app-bootstrap.yml` yet.** Apply core system components
   (`kubernetes/system/*/application.yml`) individually, in dependency order (Vault →
   ExternalSecrets → everything else), verifying each is healthy before the next. Bulk
   auto-apply comes later, once the foundation is proven — see step 6.

## 3a. k3s datastore from the off-host copy

Every 6 hours `k3s-kine-backup.timer` on `vm-srv-k3s-11` writes a consistent copy of
`state.db` (`VACUUM INTO`, integrity-checked before it leaves the VM) to `rpi-srv-02`,
`/mnt/ssd/k3s-kine/state-<UTC time>.db.zst`, kept 14 days (roles `k3s_kine_backup` and
`k3s_kine_backup_target`). Use it when PBS's copy of VM 211 is gone or older than what
you need. `K3sDatastoreBackupStale` fires when the newest copy is over 13 hours old.

1. Check the copy before using it, anywhere but the k3s server:

   ```bash
   zstd -d state-<time>.db.zst -o /tmp/state.db
   sqlite3 /tmp/state.db "PRAGMA integrity_check; SELECT count(*) FROM kine;"
   ```

2. On the k3s server: `systemctl stop k3s`, move `/var/lib/rancher/k3s/server/db/` aside,
   create it again (mode 0700) and put the copy in as `state.db` (no `-wal`/`-shm`
   files: the copy is self-contained).
3. Put the encryption key in place as in step 3 above (`k3s_secrets_encryption`), then
   `systemctl start k3s`. The cluster comes back at the copy's point in time; ArgoCD
   reconciles anything committed since.

Tested 2026-11-25 with the first copy (`state-20261125T185952Z.db.zst`, 12.8 MB) pulled
from rpi-srv-02 into a scratch directory: `integrity_check` ok, 8266 kine rows, and the
live objects in it (22 namespaces, 117 Secrets, 107 ConfigMaps, 72 Deployments, 61
ArgoCD Applications) matched `kubectl` against the running cluster. Steps 2 and 3 were
not run against the live server.

## 4. Vault — the circular dependency

A fresh Vault instance can't unseal itself. If the old cluster is truly gone, its
unseal keys are gone with it, *unless* something preserved the old cluster's own
datastore (a PBS restore of the old control-plane VM's disk counts). If so:

1. Spin up a disposable, network-isolated temporary k3s server instance pointed at the
   old cluster's preserved SQLite/kine datastore, with `secrets-encryption: true` and the
   old `encryption-config.json` (Ansible Vault `vault_k3s_encryption_config`) in its
   `server/cred/` directory. Without that key every Secret, including
   `vault-unseal-keys`, is unreadable.
2. Extract the `vault-unseal-keys` Secret from it — **never display the values**, extract
   straight to files, use immediately, delete the files after.
3. Destroy the temporary instance.
4. Restore Vault's own PVC (same local-path swap-restore pattern as any other stateful
   service — see step 5) and unseal with the recovered keys.

If the old cluster's datastore is *also* gone, there is currently no tested recovery
path for Vault — see the honest gap noted in `kubernetes/system/vault/README.md`. Build
and test a `vault operator raft snapshot`-based backup before this becomes a real
problem, not after.

## 5. Restore stateful data — the general pattern

For any `local-path`-backed service (Vaultwarden, Headscale, Garage metadata, Authelia's
Postgres via CNPG, etc.):

1. Scale the workload to 0 (plain Deployment/StatefulSet) or, for CNPG clusters,
   annotate `cnpg.io/hibernation: "on"` — **never `spec.instances: 0`, CNPG rejects it.**
2. If the target ArgoCD Application has `selfHeal: true`, either wait for the scale-down
   to actually take (it may fight you briefly) or temporarily null out
   `spec.syncPolicy.automated` on the Application — but be aware this is only a
   *temporary* suppression for `ApplicationSet`-generated Applications, since the
   ApplicationSet's own reconcile loop will re-assert its template (including
   `automated`) periodically. For anything beyond a quick fix, the real answer is
   getting the correct manifest merged to `main`, not fighting selfHeal indefinitely.
3. Mount the target PVC via a throwaway pod, copy the preserved data in.
4. **Wait for the copy to genuinely finish before touching the pod again.** A real
   mistake during this recovery: deleting a pod with `--wait=false` while a background
   `tar` extraction was still running left a half-extracted, corrupt data directory.
   Check for completion (e.g. the expected files/`postgresql.conf` actually present)
   before proceeding.
5. Un-hibernate / scale back up.
6. Verify against actual content (row counts, `sqlite3 ... "PRAGMA integrity_check;"`,
   file sizes) — not just "pod is Running."

For `nfs-client`-backed or static-PV services (Immich's library, Garage's bulk data):
these usually point at storage that's physically independent of the k3s cluster's own
lifecycle and may not need restoring at all — check what the PV actually points at
before assuming a restore is needed.

If the Immich library itself is lost, its daily hard-link snapshots live on rpi-srv-02
under `/mnt/ssd/immich-library/snapshots/<date>/` (role `immich_library_backup`). Copy the
newest snapshot back to the library path, start Immich, then run the thumbnail and video
transcoding jobs (Administration > Jobs): `thumbs/` and `encoded-video/` are not in the
mirror because Immich regenerates them from the originals.

## 5a. Postgres from the barman backups on Garage (PITR)

The first choice while Garage's `cnpg-backups` bucket survives. Every CNPG cluster
archives WAL and takes a daily base backup there through the Barman Cloud plugin
(ADR-081), 7 days of recovery window per database.

1. Make sure ArgoCD has the `cloudnative-pg` and `plugin-barman-cloud` Applications
   healthy and the `ObjectStore`s from `kubernetes/system/postgres/object-stores.yml`
   exist (`kubectl -n database get objectstore`). Each one's `.status` shows the
   recovery window it can see; an empty status means the plugin cannot read the bucket
   (check Garage, the `cnpg-garage-backup` Secret and the sidecar or plugin logs).
2. Turn off auto-sync on the `postgres-cluster` Application, then delete the broken or
   empty Cluster (its PVC goes with it; copy it aside first if it might still matter).
3. Apply a Cluster under the original name with `bootstrap.recovery` from an
   `externalClusters` plugin source, as in `kubernetes/system/postgres/README.md`
   ("How to restore"), with an optional `recoveryTarget.targetTime`. Keep the original
   `postgresql`, `managed.roles` and `resources` settings. Do not list the plugin as WAL
   archiver on the same path yet: the restored timeline must not mix into the archive
   it is reading from.
4. Verify content (row counts, the app's own login or health check), not just
   `Cluster in healthy state`.
5. Point the archiver at a fresh `destinationPath` (new `ObjectStore`, or bump the path
   in Git) and commit the Cluster exactly as applied, `bootstrap.recovery` included
   (CNPG only reads `bootstrap` when it creates the cluster), so Git matches live. Run
   an on-demand `method: plugin` Backup and re-enable auto-sync.

Tested 2026-11-17 against `postgres-scanopy`: one scratch cluster to a point before the
plugin switch, one to the latest point; both matched the live row counts.

`monthly-restore-test` (`kubernetes/system/velero/restore-test.yml`) repeats this every
month for `postgres-firefly`: a throwaway Cluster in `cnpg-restore-test` restored to the
latest point, checked (tables, rows, past the newest base backup's end LSN) and deleted.
A failure pages through ntfy.

## 5b. Postgres from the offsite (R2) backup

The offsite backup has no raw Postgres data directories, only `pg_dump` archives
(ADR-075): `/dumps/<db>.dump` on the `pg-dumps` PVC of the `pg-dump` pod in `database`
(authelia, firefly, n8n, scanopy, synapse) and in `apps` (immich, paperless, nextcloud).
`/dumps/.last-run` holds the time of the last dump. The local Garage backup and CNPG's
barman backups (local PITR) are the better source while Garage survives; use this path
when only R2 is left.

1. Let ArgoCD bring the database up empty from Git: CNPG bootstraps the cluster with its
   owner role and database, the plain StatefulSets initialise an empty PVC. The
   `postgres-*-user` secrets in `database` are applied out-of-band (`user-*.yml.example`)
   and must exist first.
2. Restore the dump pods and their PVCs (everything of theirs carries `app=pg-dump`).
   If ArgoCD already created an empty `pg-dumps` PVC, delete the `pg-dump` Deployment and
   PVC first, or Velero skips the existing PVC and its data:

   ```bash
   velero restore create --from-backup <daily-offsite-...> \
     --include-namespaces database,apps --selector app=pg-dump
   kubectl exec -n database deploy/pg-dump -- ls -l /dumps
   ```

3. Stop the application that writes to the database (scale its Deployment to 0).
4. Load the dump from the `pg-dump` pod, which has the client version the archives need
   (pg_restore 18) and every database's credentials in its environment. The names are
   the `DUMP_TARGETS` entries (`AUTHELIA FIREFLY N8N SCANOPY SYNAPSE` in `database`,
   `IMMICH PAPERLESS NEXTCLOUD` in `apps`):

   ```bash
   kubectl exec -n database deploy/pg-dump -- sh /scripts/pg-dump.sh restore SYNAPSE
   kubectl exec -n apps deploy/pg-dump -- sh /scripts/pg-dump.sh restore IMMICH
   ```

   This pipes `pg_restore --clean --if-exists --no-owner` into `psql` with
   `ON_ERROR_STOP` in a single transaction, so a failed restore leaves the database
   unchanged. immich's role is a superuser, so the vector extensions in its dump are
   recreated by the restore.
5. Scale the application back up and verify against content (row counts of a few key
   tables, the app's own UI), not just pod status.

## 6. Backup layer, then bulk workload rollout

1. Confirm a PBS backup job actually exists (`pvesh get /cluster/backup`) — this
   recovery found it completely missing, not something to assume is configured.
2. Deploy Velero + Garage, prove a real restore into a scratch namespace before trusting
   the schedule (brief §8's own explicit requirement — "a scheduled backup is not a
   restorable backup").
3. **Now** apply `kubernetes/system/argocd/apps-applicationset.yml` to bring up the
   remaining workload catalog. Before doing this, check for any Tier-1 data (from step 2)
   that belongs to an app under `kubernetes/apps/*` and hasn't been restored yet — do
   that first, or immediately after first sync via the pattern in step 5, so a fresh
   empty PVC doesn't get mistaken for "done."
4. **Expect transient chaos from simultaneous deployment.** Bulk-deploying 20-30 apps
   at once causes real, self-resolving contention: fresh Postgres instances' `initdb`
   getting interrupted (recovery: `createdb` + a broad `pg_hba.conf` rule via local
   socket, no data lost since these were legitimately fresh), and probe-timeout crash
   loops on apps with a genuinely slow first boot (recovery: loosen `failureThreshold`
   generously for first-boot-only scenarios, not permanently).

## 7. The DNS gotcha — check this on every rebuild

If the PVE host's own DNS search domain matches a wildcard rewrite rule in your DNS
server (e.g. `*.woitzik.dev`), it can silently propagate into every pod's resolv.conf
and hijack short-hostname lookups — external and internal alike. Confirmed live via
`resolvectl status` on a node and `cat /etc/resolv.conf` inside a pod; the fix
(`ansible/roles/k3s_node_tuning`'s `/etc/rancher/k3s/resolv.conf` +
`k3s-cluster/inventory.yml`'s `resolv-conf` config) should already be in place if you're
running the current Ansible role — but if pods are behaving oddly on DNS for hostnames
that look otherwise correct, check this first.

## 7b. headscale + vaultwarden: an off-host replica, not a standby

headscale and vaultwarden replicate their SQLite databases continuously to `rpi-srv-02`
(Litestream, `/mnt/ssd/litestream-replicas/`). The replica survives a `pve-mgmt-01`
loss and restores with `litestream restore` (restore-tested 2026-11-12, recovery point
under a minute old). That is a better recovery point than the nightly backups, nothing
more: there is no working standby to fail over to. The standby containers in
`/opt/ha-standby` lack headscale's identity keys and the OIDC secret and have never been
started, so `docs/runbooks/failover-headscale-vaultwarden.md` cannot be followed as
written yet. See `docs/decisions/ADR-029-warm-standby-ha-headscale-vaultwarden.md`
(2026-11-12 status) for what is missing. Every component, these two included, follows
this document's rebuild path.

## 7c. Authelia's Postgres: a streaming standby on rpi-srv-02

`postgres-authelia` streams to a hot standby on `rpi-srv-02`
(`/mnt/ssd/postgres-authelia-standby`, ADR-030), normally seconds behind. After a
`pve-mgmt-01` loss it is the freshest copy of Authelia's data, fresher than the barman
backups (5a) and the nightly dump (5b). It accepts reads without being promoted, so for
a cluster rebuild take a dump from it and restore that into the new CNPG cluster:

```bash
# on rpi-srv-02
cd /tmp && sudo -u postgres pg_dump -Fc -d authelia -f /mnt/ssd/authelia-from-standby.dump
```

Restore it as in 5b step 4 (copy the file into the primary pod and run
`pg_restore --clean --if-exists --no-owner`). Promoting the standby and pointing
Authelia at it while the cluster is still partly up is in
`docs/runbooks/failover-authelia-postgres.md`. Once a new primary exists, the standby
has to be reseeded (same runbook).

## 8. Prove it, don't assume it

Before declaring the recovery done, actually demonstrate (not just configure):
Alertmanager delivering a real alert, a certificate actually renewing, ArgoCD actually
reverting hand-introduced drift, and a real backup actually restoring.
