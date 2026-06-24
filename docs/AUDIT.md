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

### SEC-003 — Authelia session-secret and storage-key are placeholder values · **RESOLVED** (2026-06-24)

`secret/authelia` `session-secret` = `thisisaverysecretsessionsecret`;
`storage-key` = `thisisaverysecretstoragekey`. Both low-entropy, copy-pasted-looking
values. `jwt-secret` (`thisisaverysecretjwtsecret`) turned out to be the same pattern,
not originally called out, but fixed alongside it.

- **2026-06-23:** `session-secret` and `jwt-secret` regenerated with `openssl rand -hex
  32`, written to Vault, restarted Authelia clean. `storage-key` was deliberately left
  untouched at the time, believed to need extra care via `storage encryption change-key`.

- **2026-06-24, much bigger problem found while finishing this:** rotating `storage-key`
  properly requires Authelia to successfully decrypt existing data with the *old* key
  first. It couldn't — `authelia storage encryption check` reported the configured key
  invalid against the live schema. Root cause: `kubernetes/apps/authelia/configmap.yml`
  set `encryption_key: '/config/secrets/storage-key'` as a bare quoted YAML string. That
  is not a file-path reference Authelia auto-resolves — it's the literal config value.
  **The functional encryption key, this entire deployment's lifetime, has been the literal
  string `/config/secrets/storage-key`** — and the same bug affected `jwt_secret`,
  `session.secret`, and `identity_providers.oidc.hmac_secret`, all written with the same
  bare-path-string pattern (only `oidc-issuer-private-key` used Authelia's actual
  `{{ secret "..." | mindent ... }}` templating function correctly). Since this repo is a
  public portfolio artifact, that means the real JWT/session/OIDC HMAC signing secrets
  have been a publicly-visible string the entire time, not the random values Vault
  appeared to hold.
  - **Investigation mistake, corrected before any real damage:** before finding the root
    cause, the live `encryption`/`totp_configurations` rows were deleted on the (wrong)
    assumption the original key was unrecoverably lost — this would have invalidated the
    one real TOTP enrollment in the database. A `pg_dump` backup had been taken first;
    confirmed the literal-string theory by restoring the backup into an isolated temporary
    database (`authelia_verify_temp`, same Postgres instance, dropped after) and validating
    `authelia storage encryption check` against it with `--encryption-key=/config/secrets/storage-key`
    — succeeded, including the TOTP row. Restored the original rows into production from
    the same backup before making any further changes, then re-verified clean.
  - **Fix:** Changed all four fields in `configmap.yml` to
    `{{ secret "/config/secrets/X" | msquote }}`, Authelia's actual file-templating
    syntax (`X_AUTHELIA_CONFIG_FILTERS=template` was already set on the Deployment).
    Verified correct *before* committing, via an isolated test ConfigMap unmanaged by
    ArgoCD (a live `kubectl apply` of the real fix kept getting silently reverted by
    ArgoCD's `selfHeal: true` until the Git source was actually updated and merged).
  - Ran the real `authelia storage encryption change-key` (now that the true old key —
    the literal path string — was correctly identified) to re-encrypt with a fresh
    `openssl rand -hex 32` value, then updated Vault + the live Secret to match.
    `jwt-secret`/`session-secret`/`hmac-secret` already held real random values from the
    2026-06-23 pass (that rotation just hadn't taken effect yet) — no re-rotation needed,
    just the templating fix so the files actually get read now.
  - Verified live: both Authelia replicas started clean post-merge, `Storage schema is
    already up to date`, serving auth traffic normally, TOTP enrollment intact.
- **Effort:** Was small; became large once the templating bug surfaced. Done.

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

### SEC-008 — Atlantis had zero authentication and was reachable over plain HTTP · **CRITICAL** (fixed 2026-06-23)

Found while auditing Authelia coverage across all `IngressRoute`s (prompted by a request to
harden privacy/security across the board, not Atlantis-specific). Of 28 `IngressRoute`s,
`atlantis-final` was the only one with `entryPoints: [web, websecure]` — reachable over
unencrypted HTTP, not just HTTPS — and the only one with **no auth layer of any kind**: no
Authelia middleware, no `ATLANTIS_WEB_BASIC_AUTH`/username/password env vars on the
Deployment. Confirmed live: `curl -sk https://atlantis.woitzik.dev/` returned the full
Atlantis UI (PR list, plan history, repo config) with a plain `200`, no redirect to Authelia,
no password prompt.

- **Impact:** Atlantis holds the credentials and drives `terraform apply` for the entire
  homelab (Proxmox root-capable API token, MikroTik router credentials, AWS/Garage S3 keys —
  all visible to it as env vars, and plan output can echo non-`sensitive`-marked values).
  Anyone who could reach `atlantis.woitzik.dev` — any device on the LAN, or the internet if
  the domain resolves publicly — could view full Terraform plan/apply history and repo
  config with zero credentials required.
- **Why it wasn't just "add Authelia and move on":** Atlantis's GitHub webhook (`POST
  /events`, used to trigger plan/apply from PR comments) is itself authenticated via
  `ATLANTIS_GH_WEBHOOK_SECRET` (HMAC signature) — gating the whole host behind Authelia's
  forward-auth would have broken GitHub's webhook delivery, silently killing the entire
  GitOps Terraform workflow.
- **Fix (2026-06-23):** Split `atlantis-final` into two routes in
  `kubernetes/system/apps-ingressroute.yml`: `Host(...) && PathPrefix(/events)` (priority
  10, no middleware — webhook keeps its own HMAC auth) and the catch-all `Host(...)`
  (priority 1, `authelia` middleware — same pattern as every other internal tool). Also
  dropped the `web` entrypoint so it's `websecure`-only like every other service.
- **Blast radius:** UI access now requires an Authelia session; GitHub webhook delivery
  unaffected (still hits `/events` directly, still HMAC-verified).
- **Effort:** Small (1h) — done.

---

### SEC-009 — Home Assistant had no auth layer beyond its own login · **MEDIUM** (fixed 2026-06-23)

Same Authelia-coverage audit as SEC-008. Of the apps with no Authelia middleware,
`nextcloud-final` and `gitea-final` are deliberate (CalDAV/CardDAV and git protocol clients
need direct unauthenticated-at-the-edge access, both already commented in
`apps-ingressroute.yml`); `ha-final` had no such comment and no documented reason — it was
just relying on Home Assistant's own login.

- **Fix:** Added the `authelia` middleware to `ha-final`, same pattern already used for
  Jellyfin (`media-final`): Authelia gates the web UI, Companion app users should connect
  via the Headscale VPN for direct local access instead of the public hostname.
- **Blast radius:** Browser access to `ha.woitzik.dev` now requires an Authelia session
  first. If the HA Companion app was configured against the public URL directly (not
  via Headscale), it will need reconfiguring.
- **Effort:** Small — done.

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

### REL-012 — k3s control plane (etcd) crash-looping all day, 39 restarts · **CRITICAL** (discovered live 2026-06-23, not yet fixed)

Caught live while checking the homepage dashboard: `kubectl` against the API VIP and
against `vm-srv-k3s-11` directly both got connection-refused. SSH'd in and found
`k3s.service`'s systemd restart counter at 39 for the day, restart timestamps spread from
13:52 through 20:54 (roughly every 1-2h). The cluster recovered on its own within ~2
minutes each time — by the time this was investigated, nodes were `Ready` again — but it
has been silently flapping all day with nothing alerting on it.

Root cause (from `journalctl -u k3s` right before each failure): etcd `apply request took
too long` warnings up to **14.3 seconds** (expected: 100ms) on simple read-only range
requests, causing the controller-manager's leader-election lease renewal to time out
(`context deadline exceeded`), which is fatal to the k3s process (`exit code 1`) and
triggers a systemd restart. This is single-node etcd (deliberately, see GIT topology
notes) being starved of disk I/O badly enough to blow through raft's read-index timeout.

- **Likely contributing factor:** `rpool` is at 70%+ utilization (REL-005, already flagged
  but not fixed) on the single shared NVMe behind every VM/LXC on `mini`. High utilization
  degrades NVMe write latency, and this is the same physical disk class previously
  implicated in the documented ZFS/host-freeze investigation (`docs/OPERATIONS.md`).
  Today also had unusually heavy concurrent activity across LXCs (Ollama CPU inference
  stress-testing, paperless-gpt batch processing, NFS LXC near-OOM earlier) which may have
  compounded disk/CPU contention on the shared host at the same time.
- **Impact:** Every one of these episodes is a full control-plane outage (API server
  unreachable, no scheduling, no kubectl) lasting roughly 1-2 minutes, recurring multiple
  times per day, completely silently — no alert fired despite Blackbox/Prometheus already
  monitoring most services. The 39-restart count alone makes this more severe than several
  other CRITICAL-tier findings in this doc.
- **Fix (not yet done):** (1) Add alerting on `kube_node_status_condition` / API server
  reachability and on `k3s.service` restart count — this should have paged immediately.
  (2) Resolve REL-005 (free up rpool headroom) as a likely contributing factor.
  (3) Consider `etcdctl defrag` (etcd hasn't been compacted in the 24 days since the node
  last restarted cleanly) and/or moving etcd's WAL to a less-contended disk if one becomes
  available. (4) Re-evaluate whether single-node etcd on this hardware needs a lower
  `--etcd-arg` heartbeat/election-timeout tolerance, or whether the real fix is just less
  disk pressure.
- **Effort:** Alerting is small (1-2h); root-causing the I/O contention properly is
  larger and probably needs to wait for calmer conditions to test against (it's hard to
  diagnose disk contention while intentionally generating disk contention).

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

### REL-009 — Vault's raft storage was on `nfs-client` · **RESOLVED** (2026-06-24)

Same risk class as GIT-006: Vault's raft storage uses BoltDB underneath (`raft.db`,
`vault.db`), which has the same file-locking assumptions that broke Garage's SQLite
metadata DB on NFS. No corruption had occurred yet, but Vault is the root of every
secret in the cluster — worth fixing proactively rather than waiting for an incident.

- **Fix:** Took a `vault operator raft snapshot save` backup and a Proxmox VM snapshot
  of `vm-srv-k3s-11` first. Paused the ArgoCD application-controller (this Application
  has `selfHeal: true` and would otherwise fight a live StatefulSet/PVC swap).
  Scaled Vault to 0, deleted the StatefulSet with `--cascade=orphan` (keeps the PVC
  alive), copied `data-vault-0`'s contents to a new `local-path` PVC via a temporary
  pod (two hops, since the final PVC needs the exact same name `data-vault-0` for the
  Helm chart's `volumeClaimTemplate` to bind to it rather than auto-creating a new
  nfs-client one) — verified byte-identical via `md5sum` on `raft.db`/`vault.db` at
  every hop before deleting anything. Old PVC's underlying PV has `Retain` reclaim
  policy, so the original NFS data also survives independently as a second safety net.
  Updated `kubernetes/system/vault/application.yml`'s Helm value
  (`server.dataStorage.storageClass: local-path`) and re-applied (per GIT-003, this
  Application's own spec needs a manual `kubectl apply`, same as GIT-010). Vault came
  back up, auto-unsealed via the existing sidecar, `HA Mode: active`, all cluster-wide
  ExternalSecrets stayed healthy throughout.
- **Effort:** Small once the GIT-009/GIT-010 PVC-swap and Application-apply patterns
  were already established earlier the same day — done.

---

### REL-010 — `postgres-authelia` (CNPG) was on `nfs-client` · **RESOLVED** (2026-06-24)

Lower-urgency cousin of GIT-006/REL-009 (Postgres has real locking, unlike SQLite/BoltDB,
so this was flagged as LOW rather than HIGH) — migrated anyway while the pattern was
fresh from REL-009, since Authelia's auth database is still high-blast-radius if anything
ever did go wrong.

- **Fix:** Took a `pg_dump` logical backup first (in addition to the Proxmox snapshot
  already taken for REL-009 on the same node). Used CNPG's **declarative hibernation**
  feature (`cnpg.io/hibernation=on` annotation) instead of manually deleting the
  StatefulSet — this is CNPG's own documented mechanism for exactly this scenario:
  cleanly stops the instance while leaving the PVC intact. Same two-hop PVC copy as
  REL-009 (old name -> temp local-path PVC -> delete old -> final PVC named
  `postgres-authelia-1` on local-path -> copy from temp -> delete temp), verified by
  comparing total logical byte counts (`stat -c '%s'` summed across all files, not
  `du -sh` — NFS under-reports real usage via `du`, a red herring that cost some time
  mid-migration) plus `md5sum` on `PG_VERSION` and `global/pg_control`.
  - **The real complication:** a manually-created PVC isn't enough for CNPG to recognize
    it as belonging to the cluster on resume — it needs the `cnpg.io/cluster`,
    `cnpg.io/instanceName`, `cnpg.io/pvcRole=PG_DATA` labels, the `cnpg.io/nodeSerial`
    and `cnpg.io/pvcStatus=ready` annotations, **and an `ownerReference` to the Cluster**.
    Missing the ownerReference specifically caused the cluster to declare itself
    `Cluster is unrecoverable and needs manual intervention` / "restore from a recent
    backup" — a scary-sounding terminal state that was actually just one missing field,
    not real data loss (confirmed the PVC's data was always intact throughout; adding
    the ownerReference and re-cycling hibernation resolved it immediately).
  - Real data on disk (~10.4GB logical) was already larger than the declared `8Gi`
    request (NFS doesn't enforce capacity the way local-path/block storage might) —
    bumped the declared size to `12Gi` for headroom and accuracy.
- **Verified:** `totp_configurations`/`encryption` row counts unchanged post-migration,
  Authelia reconnected and served traffic normally (confirmed via a live
  `https://auth.woitzik.dev/api/health` 200 and real OIDC consent-flow traffic in logs).
- **Note:** the live `Cluster` spec briefly drifted back to `nfs-client` via ArgoCD
  self-heal before this fix was committed — cosmetic only (CNPG doesn't recreate an
  already-bound PVC just because the declared storageClass changed), but a reminder that
  GIT-003's manual-apply gap applies to *any* live edit of an ArgoCD-tracked resource,
  not just the Application objects themselves.
- **Effort:** Small in mechanics, but the CNPG label/ownerReference requirements were
  undocumented and took real investigation to find.

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

### GIT-003 — ArgoCD ApplicationSet covers only `kubernetes/apps/*`; system components are manual · **HIGH** (severity raised 2026-06-24)

The `homelab-apps` ApplicationSet auto-deploys everything under `kubernetes/apps/*` but
`kubernetes/system/*` requires manual `kubectl apply`. A merge to main of a system
component does not deploy it — it must be applied manually or via a separate ArgoCD
Application per component. Critically, this applies to the *Application objects
themselves*, not just the resources they manage: editing an existing
`kubernetes/system/<name>/application.yml` (e.g. fixing a `directory.include` glob) has
**zero effect** until someone manually re-applies that exact file — the Application's own
`spec` is not watched for drift from git at all.

Some system components (cert-manager, metallb, traefik, etc.) have their own ArgoCD
`Application` manifests inside `kubernetes/system/<name>/application.yml`, but others
do not (postgres cluster, redis, argocd itself, infrastructure resources).

- **Impact:** Drift risk for system components. A change pushed to git may not deploy
  automatically, and there is no alert when the live state diverges.
- **Confirmed real impact, not just theoretical (2026-06-24):** GIT-010's fix (correcting
  `postgres-cluster-application.yml`'s glob) merged cleanly via PR but never took live
  effect — and neither had REL-011's `ScheduledBackup` fix from earlier the same day,
  for the exact same reason. Both required a manual `kubectl apply` discovered only by
  noticing `status.history` hadn't recorded a sync since 2026-06-18.
- **Fix:** Document explicitly which system components are ArgoCD-managed vs. manual-apply.
  Add a runbook step to check `kubectl get applications -n argocd` against the list after
  every system PR merge. Longer-term: bring `kubernetes/system/*` Application objects
  themselves under a parent "app of apps" Application so edits to *them* also auto-sync —
  this is the actual fix, not just a checklist step.
- **Effort:** Small for the documentation/runbook step (done implicitly via this entry);
  larger for the real app-of-apps fix (not done).

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

### GIT-005 — Offsite Velero BackupStorageLocation has placeholder URL · **DEFERRED (deliberate, 2026-06-24)**

`kubernetes/system/velero/r2-backuplocation.yml` contains:

```yaml
s3Url: https://ACCOUNT_ID.r2.cloudflarestorage.com
```

This is a literal placeholder committed to git. The Secret (`velero-r2-credentials`) does
not yet exist in the cluster.

- **Investigated 2026-06-24:** evaluated Cloudflare R2 (zero egress fees, but no
  platform-level hard spending cap — only lifecycle rules and usage monitoring as soft
  safety nets) vs Backblaze B2 (a true hard `$0` cap that refuses writes once the free
  tier is exceeded, but charges egress on restore). Given the explicit requirement to
  never incur cost under any circumstance, decided to **skip offsite cloud backup for
  now** and rely on existing local Proxmox/PBS backups only, rather than accept R2's
  soft-cap risk or B2's restore-time egress cost.
- **Fix (if revisited):** Either credential set works once a clear cost tolerance is
  set; B2 is the safer default if the bar is "must never bill," R2 if occasional
  restore-testing cost is acceptable in exchange for zero ongoing egress risk.
- **Effort:** Small once a provider + credentials are decided.

---

### GIT-010 — `postgres-cluster` Application's directory glob never matched its ExternalSecret · **RESOLVED** (2026-06-24)

Found while verifying REL-011's `ScheduledBackup` was actually GitOps-tracked.
`postgres-cluster-application.yml`'s `directory.include` was
`'{cluster,cnpg-backup-secret,scheduled-backup}.yml'` — but the real file in that
directory is `external-secret.yml`, not `cnpg-backup-secret.yml`. `kubectl get
application postgres-cluster -o jsonpath='{.status.resources}'` confirmed only the
`Cluster` was tracked; the `cnpg-garage-backup` ExternalSecret has been running this
whole time only because it was applied manually once and never touched since — a
silent, permanent drift risk (anyone editing it in Git would see no effect at all).

- **Fix:** Corrected the glob to `'{cluster,external-secret,scheduled-backup}.yml'`.
  Verified the live `cnpg-garage-backup` ExternalSecret's spec already matches the
  repo's `external-secret.yml` exactly, so adopting it into GitOps is a clean no-op.
- **Bigger problem found applying the fix:** merging the PR alone did nothing — this
  `Application` object lives under `kubernetes/system/*`, which (per GIT-003) isn't
  covered by any ApplicationSet or parent Application. Its own spec only ever gets
  updated by a manual `kubectl apply` of `postgres-cluster-application.yml` itself;
  nothing watches it for drift from git. `kubectl get application postgres-cluster -o
  jsonpath='{.spec.source.directory.include}'` still showed the broken glob *after*
  merge, confirmed via `status.history` that the Application hadn't actually
  re-synced since 2026-06-18. This means **REL-011's `ScheduledBackup` never actually
  deployed either**, despite that PR merging cleanly — same root cause, just not
  caught until now. Ran the manual `kubectl apply` to push the corrected spec live;
  all three resources (`Cluster`, `ExternalSecret`, `ScheduledBackup`) now show
  `Synced` under `status.resources`.
- **Effort:** Trivial — done, but flags GIT-003 as more urgent than "documentation
  only": at least one real fix (REL-011) silently failed to deploy because of it.

---

### GIT-011 — Two more silent failures discovered applying WRK-006's new LXC · **RESOLVED** (2026-06-24)

Both surfaced as real `atlantis apply` errors (not silent this time) while provisioning
WRK-006's `ct_srv_media_acq_01`:

1. **The Atlantis Terraform API token isn't `root@pam`** — Proxmox only allows
   configuring `device_passthrough` on container *creation* for `root@pam`. The AI LXC's
   existing `device_passthrough` blocks (GPU passthrough) only work because that
   container was created manually as root and imported into state afterward — they
   never actually exercised the CREATE path via this token. Removed the block from the
   new LXC's create path; will add it back manually via root SSH once the bare container
   exists, then reconcile state the same way.
2. **`usb-templates` (the flaky USB scratch stick, per `CLAUDE.local.md`) is currently
   unplugged/unavailable** — confirmed via `pvesm status` on the live host, it doesn't
   even show up as a storage backend. Every existing container's
   `operating_system.template_file_id` references it, but all of them `ignore_changes`
   on that field, so it never mattered until creating a *new* container needed to
   actually fetch the template. The identical template file already exists on `local`
   (reliable disk) — switched to that.

- **Effort:** Small, but both would have silently blocked any future LXC creation
  (including the still-planned Jellyfin GPU-passthrough LXC) until hit by trial and
  error.

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
  resource — so there's no base backup to restore from via barman alone. Logged as
  `REL-011` — **RESOLVED**, see below.

---

### DOC-002 — ROADMAP.md is partially in German · **LOW**

The ROADMAP contains a mix of German and English text ("Abgeschlossen", "offen",
"benötigt"). For a public portfolio repo read by potential employers, this inconsistency
reduces readability.

- **Fix:** Translate ROADMAP.md to consistent English.
- **Effort:** Small (1h).

---

### DOC-003 — compute-nodes.md says RPi runs HAProxy/Traefik as ingress gateway — this is stale · **RESOLVED**

`docs/compute-nodes.md` lists "HAProxy / Traefik — Ingress gateway routing TCP traffic to
K3s backend" as an RPi service. The actual ingress path is MetalLB → Traefik running
inside k3s. The RPis run AdGuard + Unbound only. The table was not updated after the
ingress migration.

- **Fix:** Remove the HAProxy/Traefik line from the RPi services table; update to reflect
  AdGuard + Unbound + Keepalived only.
- **Effort:** Trivial.
- **Resolution:** Reworded the RPi section ("HA Ingress Layer" / "Gateway Strategy") to
  drop the ingress claim and added a note that MetalLB + in-cluster Traefik own k3s
  ingress; RPis only run AdGuard + Unbound + Keepalived.

---

### DOC-004 — Missing ADRs for several architectural decisions · **RESOLVED**

Decisions that were not recorded as ADRs:

- Velero + Kopia for PVC backup (the `defaultVolumesToFsBackup` fix is a significant decision)
- CloudNativePG for Authelia Postgres (migration from bare StatefulSet)
- Network policies: default-deny pattern and the rollout incident
- Vault auto-unseal design

Existing ADRs: Unbound (ADR-001), Cloudflare Tunnel (ADR-002), Garage as TF backend
(ADR-003), 3-2-1 backup (ADR-004), NFS over Longhorn (ADR-005).

Added `docs/decisions/ADR-006-cloudnativepg-authelia.md`,
`ADR-007-velero-kopia-pvc-backup.md`, `ADR-008-networkpolicy-default-deny.md`, and
`ADR-009-vault-auto-unseal.md`, each grounded in the actual git history and commit
messages behind the decision (CNPG migration commits, the 2026-06-19 Velero
`defaultVolumesToFsBackup` incident, the NetworkPolicy rollout breaking Velero→Garage and
Homepage→Uptime Kuma, and the `vault-unseal` polling-sidecar design from REL-007).

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

### WRK-004 — paperless-gpt failing on every document; Ollama iGPU crashing constantly · **RESOLVED** (2026-06-23)

`paperless-gpt` was failing 100% of auto-tagging/OCR jobs with "unexpected EOF" from the
LLM. Root cause: Ollama's AMD iGPU backend (`ct-srv-ai-01`, Ryzen 5825U/Barcelo, gfx90c)
was crashing with `vk::DeviceLostError` ("context is lost") roughly once per inference
call under any concurrent load — 451 crashes logged in a single day. This chip has no
official ROCm support; the live config had drifted to `OLLAMA_IGPU_ENABLE=1` (a Vulkan/
radv fallback path), which is what was actually crashing — not the `HSA_OVERRIDE_GFX_VERSION=9.0.0`
ROCm spoof originally declared in `ansible/roles/ollama/tasks/main.yml` (also never stable
on this chip, abandoned at some earlier point without anyone reverting the Ansible role).

- **Fix:** Switched Ollama to CPU-only (removed both GPU env vars from the systemd
  override). Verified stable under a 6-request concurrent stress test (0 crashes, all
  succeeded) before rolling out via Ansible. Restarted `paperless-gpt`; confirmed a real
  document processed end-to-end (title/tags/correspondent/date all correctly extracted,
  ~5.5 min on CPU vs. near-instant on a working GPU — slower but actually completes).
- **Separately verified, not broken:** Jellyfin's transcoding path uses a different GPU
  block entirely (VAAPI video encode/decode, not Vulkan compute) — confirmed healthy via
  `vainfo` and a real `ffmpeg` hardware encode test on the same chip. The Ollama crash says
  nothing about VAAPI's stability. However, Jellyfin currently has **no GPU passthrough
  configured at all** (separate, pre-existing gap, not something this incident caused) —
  tracked as a follow-up to move Jellyfin to its own GPU-passthrough LXC, same pattern as
  `ct_srv_ai_01`, since Proxmox iGPU passthrough is exclusive and can't be shared between
  the AI LXC and a k3s VM simultaneously.
- **Known fallout:** the document backlog that failed during the crash period was
  retried automatically by paperless-gpt's own retry logic once Ollama stabilized — but
  several documents in Paperless show garbled/hallucinated titles and content from
  earlier broken AI runs (unrelated model, predates this fix). Needs a manual data-quality
  pass, tracked separately.

---

### WRK-005 — Paperless data-quality pass: missing archives (NFS) + upside-down scans · **RESOLVED** (2026-06-24)

Two unrelated, real findings from the WRK-004 follow-up data-quality pass:

**1. 41 of 57 documents had a missing archived PDF.** `download/?original=true` worked
fine (raw scans intact) but `preview/`/`download/` (which serve the post-processing
`archive` copy) 404'd — confirmed the entire `archive/2024/` directory and most of
`archive/2023` etc. didn't exist on disk at all, while the DB still had
`archived_file_name` set. `paperless-media` is on the `nfs-client` StorageClass — same
storage class already implicated in GIT-006's SQLite corruption findings; this is very
likely the same family of NFS reliability issue, just affecting plain files instead of a
locked database this time. No data was actually lost (originals survived) — regenerated
all 41 archives via Paperless's own `python3 manage.py document_archiver -d <id> -f`
(re-derives the archive from the existing original + OCR text, no LLM involved).

**2. The 5 "hallucinated" documents (26, 44, 55, 57, 58) from WRK-004 were never actually
hallucinated — they're scanned upside down (180°).** Confirmed by pulling each original
PDF and reading it directly: all 5 are genuine, perfectly legible German documents (a
sick note, an IHK letter, a reference letter, a tax ID notice, an IHK membership notice)
that just happen to be rotated 180° in the scan. *Both* the broken text-only model
(WRK-004's root cause) *and* the now-working `minicpm-v` vision model produced fluent
nonsense when fed an upside-down page — garbled German-looking anagrams from one,
random Thai script from the other — because neither could actually read the orientation,
not because either model is fundamentally broken.

- **Fix:** `POST /api/documents/bulk_edit/` with `{"method": "rotate", "parameters":
  {"degrees": 180}}` (Paperless's native rotate action) on all 5, then re-tagged for
  OCR. Verified doc 26's rotated original renders right-side-up and fully legible.
- **Lesson for any future "AI hallucinated this" report:** check the source image's
  orientation/quality first — a vision model failing to read upside-down or badly
  skewed text looks identical to a model that's broken, but the fix is completely
  different (rotate the page vs. swap the model).
- **Effort:** Small once root-caused; the root-causing itself was the real work.

**3. Separate, not-yet-fixed issue found while watching the queue process: `LLM_MODEL`
(`qwen2.5-coder:7b`, used for title/correspondent/tag/document-type generation, distinct
from `VISION_LLM_MODEL`) occasionally responds in chatty-assistant style instead of
returning the requested short value** — e.g. for document 36, it returned a multi-
paragraph "I apologize, but I'm not able to fully understand..." explanation as the
*correspondent name*, which Paperless then rejected (`Ensure this field has no more
than 128 characters`), and a similarly long paragraph as the suggested document type
(silently ignored since it didn't match any configured type). Confirmed low-frequency
(1 failed correspondent creation, 2 chatty-refusal responses in the prior 24h of logs)
rather than systemic, but real — worth a prompt-engineering pass (more directive
system prompt, and/or truncate-and-validate suggested values before using them as
field input) if it recurs. Not fixed in this pass.

---

### WRK-006 — Media acquisition stack: dedicated VPN-isolated LXC (in progress, 2026-06-24)

SABnzbd had a hand-rolled Mullvad WireGuard kill switch (init container + manual
iptables) but the WireGuard config was a placeholder — fails closed (no leak) but
non-functional, and Sonarr/Radarr/Bazarr/NZBHydra2 had no VPN protection at all despite
making indexer/metadata queries that are arguably more privacy-sensitive than the
download traffic itself.

- **Decision:** move the whole stack to a dedicated LXC using gluetun (purpose-built
  Mullvad client + kill switch) instead of per-app sidecars, plus a standalone Tor SOCKS
  proxy for NZBHydra2's indexer queries specifically (not bulk downloads — Tor's
  bandwidth can't handle that, and doing so would be abusive to the shared network).
  Full reasoning in `docs/decisions/ADR-010-media-acquisition-lxc.md`.
- **Done:** Terraform LXC definition (`ct_srv_media_acq_01`, 10.0.20.253, modest 25GB
  root disk given `rpool` is already at ~80%), Ansible role `media_acquisition`
  (gluetun + Sonarr/Radarr/Bazarr/SABnzbd/NZBHydra2/Tor/Jellyseerr via Docker Compose,
  reusing the exact same NFS exports these apps' k8s PVCs were already bound to — no
  data migration needed), placeholder Mullvad vars in Vault.
- **Deliberately not done yet:** the LXC needs an `atlantis apply` to actually exist;
  the Ansible role can't run until it does. The old Kubernetes Deployments/PVCs and
  Traefik IngressRoutes are left untouched until the new stack is provisioned and
  verified working — cutting both over in one shot would risk a window with no
  acquisition stack running at all.
- **Still blocked on:** a real Mullvad WireGuard config (account + generated config
  from the user — can't be created on their behalf).

---

## Summary Table

| ID | Category | Severity | Title |
|---|---|---|---|
| SEC-001 | Security | **RESOLVED** | Hardcoded OIDC secret in Headscale ConfigMap — moved to Vault via ExternalSecret (2026-06-23) |
| SEC-002 | Security | **RESOLVED** | Shared OIDC client secret across 4 services |
| SEC-003 | Security | **RESOLVED** | Placeholder secrets rotated; found and fixed a much bigger bug along the way -- `configmap.yml` set 4 secret fields (jwt/session/storage-key/hmac) as bare literal strings instead of Authelia's file-templating syntax, so the *actual* functional secrets were public path strings, not the random Vault values (2026-06-24) |
| SEC-004 | Security | **RESOLVED** | Cross-service secret reuse (redis/storage/paperless) |
| REL-010 | Reliability | **RESOLVED** | `postgres-authelia` (CNPG) migrated from `nfs-client` to `local-path` via CNPG's declarative hibernation feature; required adding an ownerReference CNPG doesn't document needing (2026-06-24) |
| SEC-005 | Security | **MEDIUM** | 14 images on `:latest` / floating tags |
| SEC-006 | Security | **RESOLVED** | Kyverno enforcement policies in Audit mode |
| SEC-007 | Security | **LOW** | Proxmox provider uses `insecure = true` |
| SEC-008 | Security | **RESOLVED** | Atlantis had zero auth + plain-HTTP entrypoint -- added Authelia (webhook path excluded), HTTPS-only (2026-06-23) |
| SEC-009 | Security | **RESOLVED** | Home Assistant had no auth layer beyond its own login -- added Authelia, same pattern as Jellyfin (2026-06-23) |
| REL-001 | Reliability | **RESOLVED** | All 3 k3s nodes run continuously (`on_boot=true`); single-server topology by deliberate design, not an HA gap -- see `docs/k3s-architecture.md` |
| REL-002 | Reliability | **RESOLVED** | PBS running with `onboot=1`; `all: 1` backup job covers every VM/CT incl. k3s nodes + NFS LXC; verified successful 2026-06-23 03:00 run |
| REL-003 | Reliability | **HIGH** | Velero backend (Garage) is in-cluster; circular recovery dependency |
| REL-004 | Reliability | **HIGH** | NFS single point of failure for all PVCs |
| REL-005 | Reliability | **HIGH** | rpool at 70% utilization with no alert |
| REL-006 | Reliability | **HIGH** | No Proxmox VM snapshots for k3s nodes |
| REL-007 | Reliability | **RESOLVED** | Vault seal gap causes cascading ExternalSecret failures on restart — mitigated via faster unseal polling + wait-for-secret initContainers |
| REL-009 | Reliability | **RESOLVED** | Vault's raft storage migrated from `nfs-client` to `local-path` (same BoltDB-on-NFS risk as GIT-006), zero downtime to ExternalSecrets cluster-wide, verified byte-identical data at every copy step (2026-06-24) |
| REL-011 | Reliability | **RESOLVED** | `postgres-authelia` (CNPG) had barman WAL archiving configured but no `ScheduledBackup` resource — no base backup existed to restore from via barman alone, only the PVC itself (Velero/PBS). Added `ScheduledBackup` (`kubernetes/system/postgres/scheduled-backup.yml`), daily `0 2 * * *`, targeting the existing `barmanObjectStore` already on the Cluster; also fixed the `postgres-cluster` Application's `directory.include` glob so the new file is picked up by ArgoCD |
| REL-012 | Reliability | **CRITICAL** | k3s control plane (etcd) crash-looping all day, 39 restarts -- etcd apply latency up to 14.3s under disk I/O contention, no alerting fired |
| REL-008 | Reliability | **LOW** | uptime-kuma uses local-path storage; will lose data on node reschedule |
| GIT-001 | GitOps | **HIGH** | TF state backend requires live in-cluster Garage |
| GIT-002 | GitOps | **RESOLVED** | k3s-12/13 mistakenly retagged "master"/control-plane; reverted to "worker" (agent-only) — single-etcd design confirmed correct (2026-06-23) |
| GIT-006 | GitOps | **RESOLVED** | Garage `garage-meta` (sqlite) was on NFS (`nfs-client`); SQLite's locking/WAL model is incompatible with NFS and the metadata DB became corrupted ("database disk image is malformed" / "locking protocol" errors), breaking Velero, Loki, and TF-state writes. Recovered via `sqlite3 .recover` + cleared derived merkle/GC tables; fixed by migrating `garage-meta` to `local-path` (2026-06-23). `garage-data` (blob storage, no locking needs) remains on NFS, which is fine. Audited every other app on `nfs-client` for the same risk and found 6 more SQLite-backed apps exposed: Headscale (migrated same day, PR #50), Vaultwarden, Gitea, Mealie, Open WebUI, paperless-ai, and Home Assistant — all migrated to `local-path` 2026-06-23, each backed up and `PRAGMA integrity_check`-verified before and after. None had corrupted yet, but Vaultwarden/Open WebUI/Home Assistant were confirmed in WAL mode (the highest-risk configuration, same as Garage). |
| GIT-007 | GitOps | **RESOLVED** | `network/terraform.tfstate` did not exist in Garage at all (only `proxmox/terraform.tfstate` was present) — likely lost during the 2026-06-14 Garage/Longhorn-OOM corruption and never reconciled. Rebuilt 2026-06-23 via a full resource-by-resource `terraform import` against the live router (matched ~110 resources via REST API dumps), validated against a local scratch state with zero `terraform plan` diff before ever touching the real backend. Found and fixed along the way: (1) 15 firewall-filter resources already under `import {}` would have been destroy+recreated on apply — `place_before` has no live-readable value and was being treated as a replace-triggering field on resources that already exist correctly positioned; added `lifecycle { ignore_changes = [place_before] }` to all of them. (2) The 4 `routeros_ip_service` resources (telnet/ftp/api/api-ssl) can't use `import {}` blocks at all — a provider bug (terraform-routeros 1.99.1, latest) makes the post-import Read always fail for name-keyed resources; left them as plain resources instead, since their create function safely PATCHes the existing built-in service by name rather than creating a duplicate. (3) `fwd_12_wan_to_cobblemon` (`nat_portforward.tf`) was a byte-identical duplicate of the already-imported `fwd_wan_cobblemon` (`firewall_extra.tf`) — same live rule claimed under two Terraform addresses; removed the duplicate. |
| GIT-008 | GitOps | **LOW** | Live duplicate: `routeros_ip_firewall_mangle.mss_clamp` exists twice on the router (ids `*1` and `*5`), byte-identical config, both carrying real traffic — almost certainly created by a prior `apply` retried against the same missing state (GIT-007). Imported the lower id into Terraform; the duplicate (`*5`) still exists live and should be deleted manually via Atlantis/router once confirmed safe — not done as part of the GIT-007 state rebuild to avoid mixing state-recovery with a live destructive change. |
| GIT-009 | GitOps | **RESOLVED** | Two NAT masquerade rules (outbound WAN `*5`, MGMT->SRV `*8`) brought under Terraform via import; also found and fixed a dangling interface-list reference on `*5` (2026-06-24, needs `atlantis apply` to land) |
| GIT-010 | GitOps | **RESOLVED** | `postgres-cluster` Application's directory glob never matched its ExternalSecret filename -- silently unmanaged by GitOps since creation, fixed (2026-06-24) |
| GIT-011 | GitOps | **RESOLVED** | Two silent LXC-creation blockers found provisioning WRK-006: Atlantis's TF token isn't root@pam (blocks device_passthrough on create), and `usb-templates` storage is currently unplugged (2026-06-24) |
| GIT-003 | GitOps | **HIGH** | System components are manual-apply; no drift detection -- confirmed this silently broke both GIT-010 and REL-011's fixes until caught manually (2026-06-24) |
| GIT-004 | GitOps | **LOW** | Proxmox provider version constraint far behind latest |
| GIT-005 | GitOps | **DEFERRED** | Offsite backup (R2/B2) deliberately skipped -- neither provider offers a true no-cost guarantee that fits the "never pay" requirement without tradeoffs (2026-06-24) |
| IAC-001 | IaC | **RESOLVED** | ~50% of app Deployments lack resource limits |
| IAC-002 | IaC | **MEDIUM** | MikroTik firewall hardening apply still pending Atlantis |
| IAC-003 | IaC | **LOW** | No automated k3s VM rebuild procedure |
| DOC-001 | Docs | **HIGH** | DISASTER-RECOVERY.md does not exist |
| DOC-002 | Docs | **LOW** | ROADMAP.md is partially in German |
| DOC-003 | Docs | **RESOLVED** | compute-nodes.md has stale ingress description |
| DOC-004 | Docs | **RESOLVED** | 4 architectural decisions without ADRs — added ADR-006..009 |
| WRK-001 | Workloads | **MEDIUM** | Jellyfin/media stack stuck in ContainerCreating |
| WRK-002 | Workloads | **LOW** | Minecraft not GitOps-managed or backed up |
| WRK-003 | Workloads | **RESOLVED** | Paperless fails on cluster restart due to Vault seal gap |
| WRK-004 | Workloads | **RESOLVED** | paperless-gpt failing on every document; Ollama iGPU (Vulkan) crashing constantly under load -- switched to CPU-only |
| WRK-005 | Workloads | **PARTIAL** | Paperless data-quality pass: missing archives (nfs-client related, fixed) + 5 "hallucinated" docs were actually scanned upside-down (fixed) + LLM_MODEL occasionally returns chatty-assistant text instead of short field values (low-frequency, not fixed) (2026-06-24) |
| WRK-006 | Workloads | **IN PROGRESS** | Media acquisition stack moving to a dedicated gluetun/Mullvad-isolated LXC -- code written, blocked on `atlantis apply` + a real Mullvad config from the user (2026-06-24, ADR-010) |

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
