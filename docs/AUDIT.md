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

### SEC-002 — Authelia shared OIDC client secret across 4 services · **RESOLVED**

Generated 4 distinct client secrets (proxmox, pbs, argocd, grafana) 2026-06-23, each
hashed independently via `authelia crypto hash generate argon2` run inside the live
Authelia pod. Updated: Authelia's per-client `client_secret` hash in `configmap.yml`;
Vault `secret/argocd#oidc-client-secret` and `secret/grafana#oidc-client-secret` (both
already flow through ExternalSecret -> k8s Secret -> the consuming pod, no plumbing
changes needed); Proxmox's OIDC realm via `pvesh set /access/domains/authelia --client-key
...` and PBS's via `proxmox-backup-manager openid update authelia --client-key ...` (both
fully API/CLI-automatable, no manual UI step needed). `hmac_secret` (the third instance of
the same shared value) rotated independently as part of SEC-003/004.

Verified live: all four services' pods restarted cleanly post-rotation; Proxmox/PBS retain
their `pam`/local-root fallback login and ArgoCD/Grafana retain their local admin account,
so none of this carried real lockout risk.

---

### SEC-003 — Authelia session-secret and storage-key are placeholder values · **PARTIALLY RESOLVED**

`secret/authelia` `session-secret` = `thisisaverysecretsessionsecret`;
`storage-key` = `thisisaverysecretstoragekey`. Both low-entropy, copy-pasted-looking
values. `jwt-secret` (`thisisaverysecretjwtsecret`) turned out to be the same pattern,
not originally called out, but fixed alongside it.

- **Fixed 2026-06-23:** `session-secret` and `jwt-secret` regenerated with `openssl rand
  -hex 32`, written to Vault, restarted Authelia clean.
- **Still open:** `storage-key` was deliberately left untouched. It encrypts Authelia's
  storage backend at rest, so rotating it requires running Authelia's `storage encryption
  change-key` procedure *first* (re-encrypting existing data with the new key) — doing it
  out of order would make Authelia unable to decrypt its own database. That's a separate,
  more careful piece of work, not bundled into this pass.

---

### SEC-004 — Cross-service secret reuse: redis-password and storage-password · **RESOLVED**

Both `redis-password` and `storage-password` shared the same value as the Paperless
Postgres password (`TD3fAJ2s1cxJ`). Generated two new, independent random values
2026-06-23:

- `redis-password`: updated the `redis-secret` k8s Secret (manually managed, not
  ExternalSecret-sourced) and restarted `redis-authelia` so its `--requirepass` picks up
  the new value, then updated Vault `secret/authelia#redis-password` to match and
  restarted Authelia.
- `storage-password`: ran `ALTER USER authelia WITH PASSWORD ...` directly against the
  live `postgres-authelia` (CNPG) instance, then updated Vault to match. Deliberately
  **not** added to Authelia's ExternalSecret (see comment in `external-secret.yml`) — if
  it synced automatically from a future Vault-only edit, Authelia's DB connection would
  break until someone remembered the matching `ALTER USER` step. Both sides must be
  rotated together, manually, going forward.

Found but not fixed: `postgres-authelia` (CNPG cluster) is itself on the `nfs-client`
StorageClass — flagged as REL-010, a lower-urgency cousin of GIT-006 (Postgres has its
own robust locking, unlike SQLite/BoltDB, but NFS is still not its recommended storage).

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

### SEC-006 — Kyverno resource-limits and no-latest-tag policies in Audit mode · **RESOLVED**

Flipped both to `Enforce` 2026-06-23 after confirming zero PolicyReport violations
cluster-wide. Found and fixed two real bugs in the policies along the way:

- `disallow-latest-tag`'s `message` field referenced `{{ element.image }}` outside the
  `foreach` it was defined in — Kyverno's policy admission webhook itself now rejects
  that (newer Kyverno validates this at policy-creation time); moved the message to a
  non-element-specific form at the rule level instead.
- `require-resource-limits`'s deny condition (`element.resources.limits | length(@)`)
  crashed with a JMESPath type error under Kyverno's `autogen` controller (which
  auto-generates an equivalent Deployment/StatefulSet-level rule from the Pod-level one) —
  unlike `disallow-privileged-containers`' condition, it had no `|| <default>` fallback
  for a field that's legitimately absent in the autogenerated evaluation context.
  Rewrote as two explicit `element.resources.limits.cpu || ''` / `.memory || ''` checks,
  matching the safe pattern the privileged-containers policy already used.

Verified with a deliberate negative test (a bare Pod with no `resources:`) — correctly
rejected by the admission webhook.

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

### REL-001 — 2 of 3 k3s nodes stopped; cluster running single-node · **RESOLVED** (2026-06-23)

Originally: Proxmox live state had `vm-srv-k3s-12` and `vm-srv-k3s-13` stopped, with
`vm-srv-k3s-11` carrying the whole cluster alone. The original fix proposal (start all
three as embedded-etcd members for HA) was attempted and **reverted** — running 3
concurrent etcd writers on VMs that all share one physical host and one ZFS pool produced
enough I/O contention to freeze the host repeatedly (see `docs/compute-nodes.md`).

- **Current state:** All three nodes run continuously with `on_boot = true`.
  `vm-srv-k3s-11` is the sole control-plane + etcd server; `-12`/`-13` are agent-only
  workers, adding compute capacity without adding etcd writers. This is a deliberate
  single-server design, not an oversight — see `docs/k3s-architecture.md` §1.
- **Residual risk (accepted, not a bug):** `mini` (the physical host) remains a single
  point of failure either way — 3-way HA on one host/one disk was never actually safe.
  Target is fast *recovery* via `DISASTER-RECOVERY.md`, not zero-downtime HA.
- **Known follow-up, not yet done:** the Keepalived VIP (`10.0.20.10`) still lists
  k3s-12/13 in its failover priority from the old 3-master design even though they no
  longer run the API server — see `docs/k3s-architecture.md` §1 caveat.

---

### REL-002 — PBS backup server stopped; last VM backup was April 30, 2026 · **RESOLVED** (2026-06-23)

Originally: `ct-mgmt-pbs-01` was stopped, last successful VM backup was 7+ weeks stale,
and the k3s VMs (211/212/213) plus the NFS LXC (220) were not even in the PBS backup job's
scope.

- **Current state (verified live 2026-06-23):** `ct-mgmt-pbs-01` is running with
  `onboot=1`. The backup job (`backup-8b6a6f73-c4ce`, schedule `0 3 * * *`) uses `all: 1`,
  covering every VM/CT on the host including all three k3s VMs and the NFS LXC. The
  03:00 run completed successfully this morning (2026-06-23, 03:00–03:41) with retention
  keep-daily=7/keep-last=3/keep-weekly=4.
- **Residual gap:** PBS datastore is local to `mini` (2TB USB HDD) with rclone→Google
  Drive offsite — see `docs/backup-strategy.md`. No independent verification/alerting
  (e.g. healthchecks.io) on backup job success is wired up yet; failures would currently
  only be noticed by manually checking PBS.

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

### REL-007 — Vault sealed on startup; auto-unseal works but ExternalSecrets fail during the gap · **RESOLVED (mitigated)**

`vault-0` seals on restart; `vault-unseal` polls and auto-unseals, so this self-resolves,
but during the seal window ExternalSecrets can't sync and any pod whose Secret doesn't
exist yet (cold start / disaster-recovery rebuild, not a routine pod restart — an existing
Secret object is untouched by Vault sealing) would otherwise crash-loop on a missing
`secretKeyRef`.

ArgoCD sync waves (the originally proposed fix) turned out not to actually address this:
waves only order resources within an ArgoCD-initiated *sync*, not the pod restart order
after a node/cluster reboot, which is what kubelet drives independently of ArgoCD.

Fixed 2026-06-23 with the two changes that actually help regardless of how the restart
happens:

1. `vault-unseal` poll interval: 30s → 5s — shrinks the seal window 6x.
2. Added a `wait-for-vault-secret` initContainer to Authelia and `postgres-paperless`
   (the two apps explicitly observed crash-looping) that blocks on the expected secret
   files existing, with the secret volume marked `optional: true` so the pod can actually
   be scheduled and run the wait loop even if the Secret doesn't exist at all yet — instead
   of CrashLoopBackoff's exponential backoff, it just polls every 2s and starts the instant
   the secret appears.

**Not fixed, flagged as a new finding:** Vault's own raft storage (`data-vault-0` PVC) is
*also* on `nfs-client`. Raft uses BoltDB underneath, which has similar (though less
severe — single-writer, not WAL/shared-mmap) file-locking requirements to the SQLite
issue in GIT-006. No corruption observed so far, but given Vault is the secrets root for
half the cluster, migrating it deserves its own careful, dedicated pass (like the GIT-007
state rebuild) rather than being rushed alongside this fix.

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

### GIT-009 — Two live NAT masquerade rules were never declared in Terraform · **RESOLVED** (2026-06-24)

Confirmed live via the RouterOS REST API (`GET /rest/ip/firewall/nat`) that both rules
exist and carry real traffic, but neither had a Terraform resource:

- `*5` — outbound internet masquerade ("NAT: Outbound Internet Access"). Also turned up a
  second, unrelated problem while investigating: this rule's `out-interface-list` field
  points at interface-list id `*2000010`, which no longer exists (`GET
  /rest/interface/list` only returns the 4 RouterOS builtin lists). The rule still
  masquerades correctly because RouterOS keeps matching on the cached internal reference,
  but the management API can no longer resolve or display it by name — a dangling
  reference from some earlier, undocumented change.
- `*8` — masquerade for MGMT (VLAN 10) → SRV (VLAN 20) return traffic.

- **Fix:** Added `routeros_ip_firewall_nat.srcnat_masquerade_wan` and
  `.srcnat_masquerade_mgmt_to_srv` in `terraform/stacks/network/nat_portforward.tf`, with
  `import` blocks in `imports.tf` targeting live ids `*5`/`*8`. For `*5`, declared
  `out_interface = "ether1"` (the WAN interface used everywhere else in this codebase)
  instead of trying to recreate the dangling interface-list — verified via `terraform
  plan` (run locally, read-only, against the real backend/router) that this produces a
  clean in-place update on `*5` (swap `out_interface_list = "*2000010"` for
  `out_interface = "ether1"`) and a zero-diff import on `*8`.
- **Note:** `terraform plan` also surfaced an unrelated, pre-existing drift on
  `routeros_snmp_community.monitoring` (write-only password fields always show as a diff
  since RouterOS can't return them for comparison) — not caused by this change, left alone.
- **Blast radius:** Requires an `atlantis apply` to take effect. `*8` is a no-op apply. `*5`
  briefly recreates the WAN masquerade match criteria in place (RouterOS updates the rule's
  fields, not a delete+recreate) — should not cause a connectivity gap, but is the one part
  of this PR actually touching live, traffic-carrying WAN NAT, so apply it during a low-risk
  window.
- **Effort:** Small — code written and validated; needs `atlantis apply` to land.

---

## 4. IaC Quality

### IAC-001 — No resource limits on most Kubernetes workloads · **RESOLVED**

Most of the originally-flagged apps (bazarr, gitea, home-assistant, jellyseerr, mealie,
nzbhydra2, open-webui, radarr, sabnzbd, sonarr) picked up limits incidentally during other
work this session (image pinning, NFS migrations). Swept the remaining 16 containers
across 13 manifests on 2026-06-23 and added `resources.requests`/`limits` to all of them:
atlantis, authelia, cloudflared, garage, headscale, homepage, keel, postgres-paperless,
redis-paperless, paperless-addons (gotenberg + tika), uptime-kuma, vaultwarden, the
cloudflare-ddns CronJob, pve-exporter, and redis-authelia. Verified zero remaining gaps
via a script over every Deployment/StatefulSet/DaemonSet/CronJob in `kubernetes/`.

Also found and removed `kubernetes/system/redis/application.yml` — a stale duplicate of
`redis.yml` still referencing the long-removed Longhorn StorageClass; harmless (the live
StatefulSet already matched the current file) but dead, confusing code.

- **Fix still pending:** flip Kyverno's `require-resource-limits` policy from `Audit` to
  `Enforce` now that the gap is closed (see SEC-006).

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

### DOC-001 — No DISASTER-RECOVERY.md · **RESOLVED** (2026-06-23)

`CLAUDE.local.md` requires "A top-level DISASTER-RECOVERY.md describes full-rebuild +
per-service restore, kept current."

Added `/DISASTER-RECOVERY.md` at repo root covering all 6 required tiers (network,
Proxmox, k3s bootstrap, ArgoCD bootstrap, Vault init/unseal/ESO, Velero restore) as
runnable command sequences, plus a per-service restore table covering every node-pinned
`local-path` app, CNPG/Authelia's bootstrap-secret gotcha, Nextcloud's non-CNPG Postgres,
Jellyfin's unbacked `media` PVC, the NFS LXC's concurrency constraint, and the Cobblemon
LXC (outside k8s/ArgoCD/Velero's scope entirely). Also corrected two prerequisite stale
docs this depended on: `docs/k3s-architecture.md` (still described the reverted 3-way
HA topology) and `README.md`'s stack table (same stale claim).

- **Not yet tested end-to-end** — this is a written, reasoned-through procedure, not a
  drilled one. Treat as best-effort until an actual (or staged) recovery exercises it;
  update it with whatever doesn't match reality when that happens.
- **New gap surfaced while writing this:** CNPG's `postgres-authelia` cluster has
  continuous WAL archiving configured (barman → Garage S3) but no `ScheduledBackup`
  resource — so there's no base backup to restore from via barman alone. Logged as a new
  finding, not yet fixed — see `REL-011` below.

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

### WRK-003 — Paperless requires Vault to be unsealed; fails on cluster restart · **RESOLVED**

Specific case of REL-007 — fixed the same way (2026-06-23): `postgres-paperless` now has
a `wait-for-vault-secret` initContainer that blocks until `paperless-secrets` actually
contains `postgres-password`, instead of crash-looping. See REL-007 for the full fix.

---

## Summary Table

| ID | Category | Severity | Title |
|---|---|---|---|
| SEC-001 | Security | **RESOLVED** | Hardcoded OIDC secret in Headscale ConfigMap — moved to Vault via ExternalSecret (2026-06-23) |
| SEC-002 | Security | **RESOLVED** | Shared OIDC client secret across 4 services |
| SEC-003 | Security | **PARTIAL** | Placeholder session-secret and storage-key in Vault (storage-key still pending, needs re-encryption procedure) |
| SEC-004 | Security | **RESOLVED** | Cross-service secret reuse (redis/storage/paperless) |
| REL-010 | Reliability | **LOW** | `postgres-authelia` (CNPG) is on `nfs-client` -- same storage-class concern as GIT-006, lower severity (Postgres has real locking, unlike SQLite/BoltDB) |
| SEC-005 | Security | **MEDIUM** | 14 images on `:latest` / floating tags |
| SEC-006 | Security | **RESOLVED** | Kyverno enforcement policies in Audit mode |
| SEC-007 | Security | **LOW** | Proxmox provider uses `insecure = true` |
| REL-001 | Reliability | **RESOLVED** | All 3 k3s nodes run continuously (`on_boot=true`); single-server topology by deliberate design, not an HA gap -- see `docs/k3s-architecture.md` |
| REL-002 | Reliability | **RESOLVED** | PBS running with `onboot=1`; `all: 1` backup job covers every VM/CT incl. k3s nodes + NFS LXC; verified successful 2026-06-23 03:00 run |
| REL-003 | Reliability | **HIGH** | Velero backend (Garage) is in-cluster; circular recovery dependency |
| REL-004 | Reliability | **HIGH** | NFS single point of failure for all PVCs |
| REL-005 | Reliability | **HIGH** | rpool at 70% utilization with no alert |
| REL-006 | Reliability | **HIGH** | No Proxmox VM snapshots for k3s nodes |
| REL-007 | Reliability | **RESOLVED** | Vault seal gap causes cascading ExternalSecret failures on restart — mitigated via faster unseal polling + wait-for-secret initContainers |
| REL-009 | Reliability | **LOW** | Vault's raft storage (`data-vault-0`) is on `nfs-client`; BoltDB has similar locking needs to the SQLite issue in GIT-006, no corruption seen yet — deserves a dedicated migration pass given Vault's blast radius |
| REL-011 | Reliability | **MEDIUM** | `postgres-authelia` (CNPG) has barman WAL archiving configured but no `ScheduledBackup` resource — no base backup exists to restore from via barman alone, only the PVC itself (Velero/PBS) |
| REL-008 | Reliability | **LOW** | uptime-kuma uses local-path storage; will lose data on node reschedule |
| GIT-001 | GitOps | **HIGH** | TF state backend requires live in-cluster Garage |
| GIT-002 | GitOps | **RESOLVED** | k3s-12/13 mistakenly retagged "master"/control-plane; reverted to "worker" (agent-only) — single-etcd design confirmed correct (2026-06-23) |
| GIT-006 | GitOps | **RESOLVED** | Garage `garage-meta` (sqlite) was on NFS (`nfs-client`); SQLite's locking/WAL model is incompatible with NFS and the metadata DB became corrupted ("database disk image is malformed" / "locking protocol" errors), breaking Velero, Loki, and TF-state writes. Recovered via `sqlite3 .recover` + cleared derived merkle/GC tables; fixed by migrating `garage-meta` to `local-path` (2026-06-23). `garage-data` (blob storage, no locking needs) remains on NFS, which is fine. Audited every other app on `nfs-client` for the same risk and found 6 more SQLite-backed apps exposed: Headscale (migrated same day, PR #50), Vaultwarden, Gitea, Mealie, Open WebUI, paperless-ai, and Home Assistant — all migrated to `local-path` 2026-06-23, each backed up and `PRAGMA integrity_check`-verified before and after. None had corrupted yet, but Vaultwarden/Open WebUI/Home Assistant were confirmed in WAL mode (the highest-risk configuration, same as Garage). |
| GIT-007 | GitOps | **RESOLVED** | `network/terraform.tfstate` did not exist in Garage at all (only `proxmox/terraform.tfstate` was present) — likely lost during the 2026-06-14 Garage/Longhorn-OOM corruption and never reconciled. Rebuilt 2026-06-23 via a full resource-by-resource `terraform import` against the live router (matched ~110 resources via REST API dumps), validated against a local scratch state with zero `terraform plan` diff before ever touching the real backend. Found and fixed along the way: (1) 15 firewall-filter resources already under `import {}` would have been destroy+recreated on apply — `place_before` has no live-readable value and was being treated as a replace-triggering field on resources that already exist correctly positioned; added `lifecycle { ignore_changes = [place_before] }` to all of them. (2) The 4 `routeros_ip_service` resources (telnet/ftp/api/api-ssl) can't use `import {}` blocks at all — a provider bug (terraform-routeros 1.99.1, latest) makes the post-import Read always fail for name-keyed resources; left them as plain resources instead, since their create function safely PATCHes the existing built-in service by name rather than creating a duplicate. (3) `fwd_12_wan_to_cobblemon` (`nat_portforward.tf`) was a byte-identical duplicate of the already-imported `fwd_wan_cobblemon` (`firewall_extra.tf`) — same live rule claimed under two Terraform addresses; removed the duplicate. |
| GIT-008 | GitOps | **LOW** | Live duplicate: `routeros_ip_firewall_mangle.mss_clamp` exists twice on the router (ids `*1` and `*5`), byte-identical config, both carrying real traffic — almost certainly created by a prior `apply` retried against the same missing state (GIT-007). Imported the lower id into Terraform; the duplicate (`*5`) still exists live and should be deleted manually via Atlantis/router once confirmed safe — not done as part of the GIT-007 state rebuild to avoid mixing state-recovery with a live destructive change. |
| GIT-009 | GitOps | **RESOLVED** | Two NAT masquerade rules (outbound WAN `*5`, MGMT->SRV `*8`) brought under Terraform via import; also found and fixed a dangling interface-list reference on `*5` (2026-06-24, needs `atlantis apply` to land) |
| GIT-003 | GitOps | **MEDIUM** | System components are manual-apply; no drift detection |
| GIT-004 | GitOps | **LOW** | Proxmox provider version constraint far behind latest |
| GIT-005 | GitOps | **LOW** | R2 BackupStorageLocation has placeholder URL committed |
| IAC-001 | IaC | **RESOLVED** | ~50% of app Deployments lack resource limits |
| IAC-002 | IaC | **MEDIUM** | MikroTik firewall hardening apply still pending Atlantis |
| IAC-003 | IaC | **LOW** | No automated k3s VM rebuild procedure |
| DOC-001 | Docs | **HIGH** | DISASTER-RECOVERY.md does not exist |
| DOC-002 | Docs | **LOW** | ROADMAP.md is partially in German |
| DOC-003 | Docs | **LOW** | compute-nodes.md has stale ingress description |
| DOC-004 | Docs | **LOW** | 4 architectural decisions without ADRs |
| WRK-001 | Workloads | **MEDIUM** | Jellyfin/media stack stuck in ContainerCreating |
| WRK-002 | Workloads | **LOW** | Minecraft not GitOps-managed or backed up |
| WRK-003 | Workloads | **RESOLVED** | Paperless fails on cluster restart due to Vault seal gap |

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
