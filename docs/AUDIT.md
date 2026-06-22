# Homelab Infrastructure Audit

**Date:** 2026-06-22
**Scope:** Full repo + live cluster + Proxmox host
**Method:** Static analysis of all manifests, Terraform, and Ansible; live `kubectl` queries;
SSH to `pve-mgmt-01` for Proxmox/ZFS state.

Severity scale: **CRITICAL** (data loss or full outage risk) · **HIGH** (security exposure or
significant reliability gap) · **MEDIUM** (quality debt, partial coverage) · **LOW** (minor
style or hygiene).

---

## 1. Security

### SEC-001 — Hardcoded OIDC client secret in Headscale ConfigMap · **HIGH**

`kubernetes/apps/headscale/config.yml` contains:

```yaml
client_secret: "headscale-pass-2026"
```

This is a plaintext credential in a Git-committed manifest. All other OIDC clients
(Proxmox, PBS, ArgoCD, Grafana) store their client secrets in Vault and inject via
ExternalSecret. Headscale is the only exception.

- **Impact:** Anyone with repo read access (it is public) has the Authelia OIDC client
  secret for the Headscale/Tailscale control plane.
- **Fix:** Move to Vault `secret/headscale`, create an ExternalSecret → Secret, and
  reference via `secretKeyRef` in the Headscale ConfigMap. Rotate the value immediately.
- **Blast radius:** Headscale restart required; Tailscale clients reconnect automatically.
- **Effort:** Small (1–2h).

---

### SEC-002 — Authelia shared OIDC client secret across 4 services · **HIGH**

Per `docs/secrets-inventory.md`: Proxmox, PBS, ArgoCD, and Grafana share one OIDC client
secret. Additionally, `hmac_secret` in Vault was found to be the same value as this shared
secret (`dubist1plebyakalb`) — a third instance of the same value.

- **Impact:** Compromise of any one client's side (e.g., a Proxmox config export) exposes
  credentials for all four, including the hypervisor.
- **Fix:** Generate four distinct client secrets; update Authelia's per-client hash
  (`argon2id` via `authelia crypto hash generate argon2`); update Vault `secret/argocd`,
  `secret/grafana`; re-enter in Proxmox/PBS OIDC realm UI. Rotate `hmac_secret`
  independently.
- **Effort:** Medium (3–4h for all four clients + hmac_secret).

---

### SEC-003 — Authelia session-secret and storage-key are placeholder values · **HIGH**

`secret/authelia` `session-secret` = `thisisaverysecretsessionsecret`;
`storage-key` = `thisisaverysecretstoragekey`. Both are low-entropy strings that appear
to be copy-pasted from example configs.

- **Impact:** Session tokens and the storage encryption layer are weaker than intended.
  An attacker who obtains a session cookie has an easier brute-force path.
- **Fix:** Regenerate both with `openssl rand -hex 64`; update Vault; restart Authelia.
  Note: changing `storage-key` requires re-encrypting the storage database — follow
  Authelia's `authelia storage encryption change-key` procedure first.
- **Effort:** Small but careful (1–2h; must not skip the re-encryption step).

---

### SEC-004 — Cross-service secret reuse: redis-password and storage-password · **MEDIUM**

Both share the same value as the Paperless Postgres password (`TD3fAJ2s1cxJ`). Three
unrelated services accept the same credential.

- **Impact:** A credential leak in any one service (Paperless DB, Authelia Redis,
  Authelia storage) gives access to all three.
- **Fix:** Generate unique values; update Vault; restart affected pods.
- **Effort:** Small (1h each, do together with SEC-002/003).

---

### SEC-005 — 14 container images pinned to `:latest` or floating tags · **MEDIUM**

Images using `:latest` or equivalent:

| App | Image |
|---|---|
| paperless-gpt | `icereed/paperless-gpt:latest` |
| paperless-ngx | `ghcr.io/paperless-ngx/paperless-ngx:latest` |
| cloudflared | `cloudflare/cloudflared:latest` |
| vaultwarden | `vaultwarden/server:latest` |
| apache tika | `apache/tika:latest` |
| paperless-ai | `clusterzx/paperless-ai:latest` |
| homepage | `ghcr.io/gethomepage/homepage:latest` |
| jellyfin | `jellyfin/jellyfin:latest` |
| jellyseerr | `fallenbagel/jellyseerr:latest` |
| sabnzbd | `lscr.io/linuxserver/sabnzbd:latest` |
| sonarr | `lscr.io/linuxserver/sonarr:latest` |
| radarr | `lscr.io/linuxserver/radarr:latest` |
| bazarr | `lscr.io/linuxserver/bazarr:latest` |
| nzbhydra2 | `lscr.io/linuxserver/nzbhydra2:latest` |

Also: `open-webui:main`, `gitea:1.22` (major-only), `uptime-kuma:1` (major-only),
`renovate:39` (major-only), `pve-exporter:latest` (system).

- **Impact:** Unpredictable upgrades; rollback impossible without a digest; Kyverno
  `disallow-latest-tag` policy is in Audit (not Enforce) specifically because of this debt.
- **Fix:** Pin each to a specific semver digest. Renovate is already deployed and can
  automate digest-pinning PRs once its GitHub PAT secret is applied.
- **Effort:** Medium (bulk PR; Renovate handles ongoing maintenance once bootstrapped).

---

### SEC-006 — Kyverno resource-limits and no-latest-tag policies in Audit mode · **MEDIUM**

Both `require-resource-limits` and `disallow-latest-tag` are `validationFailureAction: Audit`.
This means violations are logged to PolicyReport but not blocked.

- **Impact:** New deployments without limits or with `:latest` tags slip through undetected.
- **Fix:** After SEC-005 is remediated (images pinned), flip both to `Enforce`.
- **Effort:** Trivial once SEC-005 is done.

---

### SEC-007 — Proxmox provider uses insecure TLS (`insecure: true`) · **LOW**

`terraform/stacks/proxmox/providers.tf` sets `insecure = true` — skips TLS certificate
verification when talking to the Proxmox API.

- **Impact:** On the local management VLAN this is low risk, but it means MITM on VLAN 10
  could intercept API calls including the API token.
- **Fix:** Add the Proxmox self-signed CA cert to the TF provider's `tls_client_config`,
  or issue a cert-manager certificate for the Proxmox web UI from the Let's Encrypt wildcard.
- **Effort:** Small.

---

## 2. Reliability / Recoverability

### REL-001 — 2 of 3 k3s nodes stopped; cluster running single-node · **CRITICAL**

Proxmox live state: `vm-srv-k3s-12` and `vm-srv-k3s-13` are `stopped`. Only `vm-srv-k3s-11`
is running. The etcd quorum requires 2 of 3 nodes — with only one running, the cluster has
no fault tolerance. If `vm-srv-k3s-11` goes down, the entire cluster is unavailable and
etcd must be recovered from backup.

- **Impact:** Total cluster outage on single node failure. All GitOps-managed workloads
  (Vaultwarden, Nextcloud, Paperless, etc.) go down simultaneously.
- **Fix:** Start k3s-12 and k3s-13 (manually, given `onboot=0`). Verify all three appear
  as `Ready` nodes and etcd shows 3 members.
- **Blast radius:** None — starting stopped VMs only adds nodes to the cluster.
- **Effort:** Minutes.

---

### REL-002 — PBS backup server stopped; last VM backup was April 30, 2026 · **CRITICAL**

`ct-mgmt-pbs-01` is `stopped`. The PBS datastore (`/mnt/pbs-storage`) shows the last
backup was 2026-04-30 — over 7 weeks ago. PBS is the only VM-level backup mechanism.
Velero covers k8s workloads but not the VM disks themselves.

Additionally: PBS datastore backups covered only LXC 110, 200, 301, 302. The k3s VMs
(211, 212, 213) and NFS LXC (220) are **not** in PBS backup jobs.

- **Impact:** VM-level recovery path is unavailable. If k3s-11's disk fails, recovery
  requires rebuilding k3s from scratch (k3s install → ArgoCD bootstrap → Vault inject →
  Velero restore). No PBS snapshot for the NFS server means NFS data (130 GB used) has
  no VM-level backup — only Velero, which backs up PVC contents, not the NFS server config.
- **Fix:**
  1. Start `ct-mgmt-pbs-01`.
  2. Add k3s VMs (211, 212, 213) and NFS LXC (220) to PBS backup jobs.
  3. Set `onboot=1` for PBS so it starts automatically after a host reboot.
  4. Verify backup runs successfully and alert on failure (healthchecks.io).
- **Effort:** Medium (2–3h including Proxmox backup job config).

---

### REL-003 — Velero S3 backend (Garage) is in-cluster; circular dependency on recovery · **HIGH**

Velero backups are stored in Garage S3, which itself runs as a k3s pod. If the cluster is
lost entirely (not just a namespace failure), Garage goes down with it, making the Velero
backups unreachable until Garage is restored — but restoring Garage requires the cluster
to be up.

The offsite backup to Cloudflare R2 (`daily-offsite` schedule) would break this dependency,
but it is **not yet active** — waiting on R2 Account ID and API token.

- **Impact:** Full cluster loss → Velero backups inaccessible until the cluster is rebuilt
  enough to run Garage again. Recovery is possible but more complex than it should be.
- **Fix:** Provide R2 credentials and activate `velero-r2-credentials` Secret and the
  `daily-offsite` Schedule. This is the missing third copy in the 3-2-1 rule.
- **Effort:** Small once R2 credentials are in hand (30 min).

---

### REL-004 — NFS server is a single point of failure for all PVCs · **HIGH**

All k3s PVCs (except `uptime-kuma-data` which uses `local-path`) are backed by
`ct-srv-nfs-01`. If NFS goes down (LXC crash, NFS daemon hang, host issue), every
stateful pod in the cluster loses its volume simultaneously.

The NFS server's data lives on `rpool/nfs-data` (ZFS on the single NVMe SSD). ZFS
protects against corruption, not disk failure.

- **Impact:** Full data unavailability for all stateful apps (Nextcloud, Vaultwarden,
  Paperless, Postgres, etc.) until NFS is restored. No automatic failover.
- **Fix (short term):** Add NFS healthcheck to Uptime Kuma; set `onboot=1` for
  `ct-srv-nfs-01` (it's currently `onboot=0`).
- **Fix (long term):** Consider a second NFS export from the host directly (as a warm
  standby), or migrate critical PVCs to CNPG WAL archiving + Velero for independent recovery.
- **Effort:** Short-term is minutes; long-term is significant.

---

### REL-005 — rpool data volume at 70% utilization · **HIGH**

`rpool/data`: 292 GB used, 129 GB available (out of ~420 GB). The AI LXC alone uses 43 GB
(`subvol-201-disk-0`) and the Docker LXC uses 16 GB. With k3s VMs each using 72–74 GB of
the 120 GB allocated, available space will tighten as workloads grow.

- **Impact:** When rpool fills, ZFS writes fail, which freezes the host. This contributed
  to the June 2026 freeze investigation.
- **Fix:** Clean up unused snapshot space (`zfs list -t snapshot`), review AI LXC disk
  allocation (42.9 GB used of allocated), consider compressing large volumes with
  `zfs set compression=zstd`. Alert when rpool exceeds 80% (`zpool list` Prometheus metric).
- **Effort:** Medium.

---

### REL-006 — No VM-level Proxmox snapshots for k3s nodes · **HIGH**

`pvesh get /nodes/pve-mgmt-01/qemu/211/snapshot` returns only `current` — no named
pre-change snapshots. The CLAUDE.local.md guardrail #1 requires a snapshot before any
change affecting running state.

- **Impact:** No VM-level rollback point if a k3s upgrade or OS change goes wrong.
  Recovery falls back to PBS restore (when PBS is running) or k3s rebuild from scratch.
- **Fix:** Take a named Proxmox snapshot before any infra change:
  `qm snapshot 211 pre-<change> --description "..."`. Add to runbook.
- **Effort:** Trivial (command takes <30 seconds per VM).

---

### REL-007 — Vault sealed on startup; auto-unseal works but ExternalSecrets fail during the gap · **MEDIUM**

`vault-0` StatefulSet shows 0/1 ready in recent observations (sealed on restart). The
`vault-unseal` Deployment polls every 30 seconds and unseals automatically — so this
resolves itself. However, during the seal window, ExternalSecrets fail to sync, and any
pod that tries to start during that gap (e.g., Authelia on cluster restart) will fail to
read its secrets.

The current restart ordering (cluster → all pods start simultaneously → Vault starts late →
ExternalSecrets fail) causes cascading failures visible as Authelia crashlooping on cluster
restarts.

- **Impact:** Every cluster restart causes a temporary (minutes) secret-sync failure across
  all apps using ExternalSecrets. Authelia takes 3–5 crashloop iterations before recovering.
- **Fix:** Add ArgoCD sync waves to ensure Vault (wave 0) + ExternalSecrets (wave 1) sync
  and are healthy before app deployments (wave 2+). Or add an init container to Authelia
  that waits for Vault readiness.
- **Effort:** Medium (ArgoCD sync waves across multiple Applications).

---

### REL-008 — uptime-kuma uses local-path storage (single-node, non-NFS) · **LOW**

`uptime-kuma-data` PVC uses `local-path` StorageClass rather than `nfs-client`. This means
the data is stored on the node's local disk (`/var/lib/rancher/k3s/storage`), which is the
k3s-11 VM disk.

- **Impact:** If pods reschedule to a different node (once k3s-12/13 are running again),
  uptime-kuma loses its data. In a 3-node cluster this is a real scheduling risk.
- **Fix:** Migrate to `nfs-client` StorageClass (consistent with all other PVCs).
- **Effort:** Small (PVC migration, Velero backup of current data first).

---

## 3. GitOps Quality

### GIT-001 — Terraform state backend requires live Garage (in-cluster) · **HIGH**

Both Terraform stacks use `backend "s3"` pointing to `http://garage.apps.svc.cluster.local:3900`.
This means `terraform init` and `atlantis plan/apply` require the cluster and Garage pod to
be healthy. If Garage is down (cluster restart, PVC issue), Terraform operations block
entirely.

- **Impact:** During a cluster recovery scenario (exactly when you'd want to run Terraform),
  the Terraform backend is also unavailable.
- **Fix:** Set up a Cloudflare R2 or external S3-compatible backend as a fallback, or
  document a manual state unlock procedure. At minimum, keep a local copy of the state file.
- **Effort:** Medium.

---

### GIT-002 — k3s-12 and k3s-13 labels say "worker" in Terraform but they're control-plane nodes · **LOW**

`vm.tf` tags k3s-12 and k3s-13 as `["k3s", "worker", "kubernetes"]` — but they were
migrated to control-plane + etcd nodes in June 2026. The Terraform tags are stale.

- **Fix:** Update tags to `["k3s", "control-plane", "etcd", "kubernetes"]` in `vm.tf`.
- **Effort:** Trivial.

---

### GIT-003 — ArgoCD ApplicationSet covers only `kubernetes/apps/*`; system components are manual · **MEDIUM**

The `homelab-apps` ApplicationSet auto-deploys everything under `kubernetes/apps/*` but
`kubernetes/system/*` requires manual `kubectl apply`. A merge to main of a system
component does not deploy it — it must be applied manually or via a separate ArgoCD
Application per component.

Some system components (cert-manager, metallb, traefik, etc.) have their own ArgoCD
`Application` manifests inside `kubernetes/system/<name>/application.yml`, but others
do not (postgres cluster, redis, argocd itself, infrastructure resources).

- **Impact:** Drift risk for system components. A change pushed to git may not deploy
  automatically, and there is no alert when the live state diverges.
- **Fix:** Document explicitly which system components are ArgoCD-managed vs. manual-apply.
  Add a runbook step to check `kubectl get applications -n argocd` against the list after
  every system PR merge.
- **Effort:** Documentation only (small).

---

### GIT-004 — Proxmox provider version uses pessimistic constraint `~> 0.69` · **LOW**

`terraform/stacks/proxmox/providers.tf` uses `version = "~> 0.69"` for the `bpg/proxmox`
provider. The latest available is v0.100.x. This constraint allows upgrades within the
0.x minor series but the current pinned version is far behind.

The network stack (`routeros`) pins to an exact version (`1.99.1`), which is better practice.

- **Fix:** Update to a specific version (`version = "0.100.0"` or current latest); test
  with `terraform plan`; commit the updated `.terraform.lock.hcl`.
- **Effort:** Small.

---

### GIT-005 — Offsite Velero BackupStorageLocation has placeholder URL · **LOW**

`kubernetes/system/velero/r2-backuplocation.yml` contains:

```yaml
s3Url: https://ACCOUNT_ID.r2.cloudflarestorage.com
```

This is a literal placeholder committed to git. The Secret (`velero-r2-credentials`) does
not yet exist in the cluster.

- **Fix:** Once R2 credentials are available, replace `ACCOUNT_ID` with the real value
  and create the Secret via ExternalSecret (Vault `secret/cloudflare-r2`).
- **Effort:** Small once credentials are in hand.

---

## 4. IaC Quality

### IAC-001 — No resource limits on most Kubernetes workloads · **MEDIUM**

Of 40 manifest files in `kubernetes/apps/`, 19 define `resources:`. The remaining 21 have
no `limits` or `requests`. This means Kyverno's `require-resource-limits` policy fires on
every pod creation in `apps`, `monitoring`, and `database` namespaces — all in Audit mode,
so it's logged but not enforced.

Specific services missing limits: bazarr, cloudflared, gitea, headscale, home-assistant,
jellyseerr, keel, mealie, nzbhydra2, open-webui, radarr, sabnzbd, sonarr, vaultwarden.

- **Impact:** A runaway pod can starve other workloads on the single-node cluster.
  This is particularly risky given the marginal host memory budget (AI LXC uses 32 GB,
  leaving ~30 GB for 3 k3s VMs + host).
- **Fix:** Add `resources.requests` and `resources.limits` to all Deployments; then flip
  Kyverno policy to `Enforce`.
- **Effort:** Medium (bulk change across 20+ manifests).

---

### IAC-002 — MikroTik firewall hardening apply pending Atlantis · **MEDIUM**

Per `docs/OPERATIONS.md`: `terraform/stacks/network/imports.tf` is committed and validates
clean, but has never been applied via Atlantis because Atlantis itself is k3s-hosted (and
Garage, which backs the TF state, is also k3s-hosted). Any Atlantis apply requires the
cluster to be fully healthy first.

- **Impact:** Firewall hardening rules are in Git but not live on the router. The live
  MikroTik config may have drifted from the Terraform-defined state.
- **Fix:** Once cluster is stable, trigger `atlantis apply` on the network stack.
- **Effort:** Trivial once cluster is up.

---

### IAC-003 — No Ansible role for k3s VM provisioning (cloud-init only) · **LOW**

k3s VMs are provisioned via Terraform with cloud-init. There is no Ansible role for
post-provisioning k3s configuration (aside from the `k3s-cluster/` sub-repo). If a k3s
VM needs to be rebuilt, the process is partially documented in `docs/k3s-architecture.md`
but is not fully automated.

- **Fix:** Document the exact rebuild procedure in `docs/disaster-recovery.md` (which
  doesn't exist yet — see DOC-001).
- **Effort:** Documentation.

---

## 5. Documentation

### DOC-001 — No DISASTER-RECOVERY.md · **HIGH**

`CLAUDE.local.md` requires "A top-level DISASTER-RECOVERY.md describes full-rebuild +
per-service restore, kept current." The ROADMAP also lists this as a pending item.

This document does not exist. `docs/backup-strategy.md` covers the backup mechanics but
not the step-by-step rebuild procedure.

- **Impact:** In an actual disaster, the operator must reconstruct the recovery steps
  from multiple fragmented docs (k3s-architecture.md, backup-strategy.md, secrets-inventory.md,
  ROADMAP.md). Under stress, this increases MTTR significantly.
- **Fix:** Write `DISASTER-RECOVERY.md` covering: (1) Proxmox rebuild from PBS, (2) k3s
  cluster bootstrap from bare VMs, (3) ArgoCD bootstrap, (4) Vault init + unseal,
  (5) ExternalSecrets sync, (6) Velero restore. Each step should be a runnable command
  sequence.
- **Effort:** Medium (3–4h to write; requires testing to verify).

---

### DOC-002 — ROADMAP.md is partially in German · **LOW**

The ROADMAP contains a mix of German and English text ("Abgeschlossen", "offen",
"benötigt"). For a public portfolio repo read by potential employers, this inconsistency
reduces readability.

- **Fix:** Translate ROADMAP.md to consistent English.
- **Effort:** Small (1h).

---

### DOC-003 — compute-nodes.md says RPi runs HAProxy/Traefik as ingress gateway — this is stale · **LOW**

`docs/compute-nodes.md` lists "HAProxy / Traefik — Ingress gateway routing TCP traffic to
K3s backend" as an RPi service. The actual ingress path is MetalLB → Traefik running
inside k3s. The RPis run AdGuard + Unbound only. The table was not updated after the
ingress migration.

- **Fix:** Remove the HAProxy/Traefik line from the RPi services table; update to reflect
  AdGuard + Unbound + Keepalived only.
- **Effort:** Trivial.

---

### DOC-004 — Missing ADRs for several architectural decisions · **LOW**

Decisions not recorded as ADRs:

- Velero + Kopia for PVC backup (the `defaultVolumesToFsBackup` fix is a significant decision)
- CloudNativePG for Authelia Postgres (migration from bare StatefulSet)
- Network policies: default-deny pattern and the rollout incident
- Vault auto-unseal design

Existing ADRs: Unbound (ADR-001), Cloudflare Tunnel (ADR-002), Garage as TF backend
(ADR-003), 3-2-1 backup (ADR-004), NFS over Longhorn (ADR-005).

- **Fix:** Write ADR-006 through ADR-009 for the above decisions.
- **Effort:** Small (1h each).

---

## 6. Useful-Workload Gaps

### WRK-001 — Jellyfin and media stack stuck in ContainerCreating · **MEDIUM**

At audit time: `jellyfin`, `jellyseerr`, `sabnzbd`, `sonarr`, `radarr`, `bazarr`,
`nzbhydra2` all in `ContainerCreating`. The `media` PVC uses a directly-declared NFS
PersistentVolume (`media-nfs`) at `10.0.10.10:/mnt/media`. Per ZFS output, the
`archive/media` dataset has only 160 KB used — the NFS share may be empty or unmounted.

- **Fix:** Verify the NFS export on the Proxmox host for `/mnt/media`, confirm the
  `media-nfs` PV is bound, and restart the Jellyfin pod.
- **Effort:** Small (30 min debugging).

---

### WRK-002 — Minecraft not GitOps-managed · **LOW**

CLAUDE.local.md lists Minecraft as a target useful workload ("fully GitOps-managed,
backed up, and documented"). The game server runs in `ct-dmz-games-01` via
`docker/crafty/` (Docker Compose). It is not exposed through k3s, not backed up via
Velero, and has no runbook.

- **Fix:** Either document the Crafty/Docker Compose setup properly with a backup strategy
  for world data, or migrate to a k3s Deployment with NFS PVC for world persistence and
  Velero backup coverage.
- **Effort:** Medium.

---

### WRK-003 — Paperless requires Vault to be unsealed; fails on cluster restart · **MEDIUM**

Paperless reads its database password via ExternalSecret from Vault. On cluster restart,
Vault is sealed for ~30–60 seconds. Paperless starts before Vault is unsealed, cannot
read its secrets, and fails. Once Vault is unsealed, the ExternalSecret syncs and Paperless
recovers — but this adds significant startup delay and noisy error logs.

This is a specific case of REL-007 (Vault seal gap) with high user visibility (documents
inaccessible after every restart).

- **Fix:** ArgoCD sync waves (see REL-007 fix). Alternatively, add an `initContainer`
  to Paperless that polls the ExternalSecret for a `Ready` condition before starting.
- **Effort:** Medium.

---

## Summary Table

| ID | Category | Severity | Title |
|---|---|---|---|
| SEC-001 | Security | **HIGH** | Hardcoded OIDC secret in Headscale ConfigMap |
| SEC-002 | Security | **HIGH** | Shared OIDC client secret across 4 services |
| SEC-003 | Security | **HIGH** | Placeholder session-secret and storage-key in Vault |
| SEC-004 | Security | **MEDIUM** | Cross-service secret reuse (redis/storage/paperless) |
| SEC-005 | Security | **MEDIUM** | 14 images on `:latest` / floating tags |
| SEC-006 | Security | **MEDIUM** | Kyverno enforcement policies in Audit mode |
| SEC-007 | Security | **LOW** | Proxmox provider uses `insecure = true` |
| REL-001 | Reliability | **CRITICAL** | 2 of 3 k3s nodes stopped; no etcd quorum |
| REL-002 | Reliability | **CRITICAL** | PBS stopped; last VM backup 7+ weeks ago; k3s VMs not in backup scope |
| REL-003 | Reliability | **HIGH** | Velero backend (Garage) is in-cluster; circular recovery dependency |
| REL-004 | Reliability | **HIGH** | NFS single point of failure for all PVCs |
| REL-005 | Reliability | **HIGH** | rpool at 70% utilization with no alert |
| REL-006 | Reliability | **HIGH** | No Proxmox VM snapshots for k3s nodes |
| REL-007 | Reliability | **MEDIUM** | Vault seal gap causes cascading ExternalSecret failures on restart |
| REL-008 | Reliability | **LOW** | uptime-kuma uses local-path storage; will lose data on node reschedule |
| GIT-001 | GitOps | **HIGH** | TF state backend requires live in-cluster Garage |
| GIT-002 | GitOps | **LOW** | k3s-12/13 tagged "worker" in Terraform; now control-plane |
| GIT-003 | GitOps | **MEDIUM** | System components are manual-apply; no drift detection |
| GIT-004 | GitOps | **LOW** | Proxmox provider version constraint far behind latest |
| GIT-005 | GitOps | **LOW** | R2 BackupStorageLocation has placeholder URL committed |
| IAC-001 | IaC | **MEDIUM** | ~50% of app Deployments lack resource limits |
| IAC-002 | IaC | **MEDIUM** | MikroTik firewall hardening apply still pending Atlantis |
| IAC-003 | IaC | **LOW** | No automated k3s VM rebuild procedure |
| DOC-001 | Docs | **HIGH** | DISASTER-RECOVERY.md does not exist |
| DOC-002 | Docs | **LOW** | ROADMAP.md is partially in German |
| DOC-003 | Docs | **LOW** | compute-nodes.md has stale ingress description |
| DOC-004 | Docs | **LOW** | 4 architectural decisions without ADRs |
| WRK-001 | Workloads | **MEDIUM** | Jellyfin/media stack stuck in ContainerCreating |
| WRK-002 | Workloads | **LOW** | Minecraft not GitOps-managed or backed up |
| WRK-003 | Workloads | **MEDIUM** | Paperless fails on cluster restart due to Vault seal gap |

---

## Drift Detection

| Resource | Git state | Live state | Delta |
|---|---|---|---|
| k3s-11 | Running, control-plane | Running (Ready) | OK |
| k3s-12 | Running, control-plane | **Stopped** | DRIFT — needs start |
| k3s-13 | Running, control-plane | **Stopped** | DRIFT — needs start |
| ct-mgmt-pbs-01 | Running (implied by backup strategy) | **Stopped** | DRIFT |
| ct-srv-nfs-01 | Running (required by all PVCs) | Running | OK |
| ct-srv-ai-01 | Running (Ollama required by paperless-gpt) | **Stopped** | DRIFT |
| ct-srv-docker-01 | Running (app_nodes group) | **Stopped** | DRIFT |
| ct-dmz-proxy-01 | Running | **Stopped** | DRIFT |
| ct-dmz-games-01 | Running | **Stopped** | DRIFT |
| ArgoCD Applications | All apps Synced | All Synced | OK |
| vault-0 StatefulSet | 1/1 | 0/1 (sealed on restart) | Transient — resolves with auto-unseal |
| headscale client_secret | Should be in Vault | In ConfigMap plaintext | DRIFT |
