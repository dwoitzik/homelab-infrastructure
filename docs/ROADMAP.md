# Homelab Roadmap

> **2026-08-17: moved to `docs/ROADMAP.md`** (was at repo root — BRIEFING-V4.md
> references `docs/ROADMAP.md` throughout, this file's actual location didn't match).
> **Most of the content below predates the 2026-08-13 disaster-recovery rebuild** (the
> LMDB/Terraform-state wipe, the full cluster rebuild that followed — see
> `DISASTER-RECOVERY.md` and `phase8/LEDGER.md`) and describes the *pre-rebuild*
> architecture: Longhorn (removed, migrated to `nfs-client`/`local-path` well before the
> rebuild too, per this file's own "In Progress" table below — still stale either way),
> Chaos Mesh, a since-abandoned Cilium plan, and dated entries from June 2026. Kept as
> historical record rather than deleted (same discipline as `CHANGELOG.md`'s dated
> entries), but **do not treat anything below this notice as current architecture**
> without checking it against `docs/compute-nodes.md`, `docs/k3s-architecture.md`, and
> the live cluster first. A full rewrite against current reality is a real, separate
> piece of work (BRIEFING-V4.md Section H, "clean the tree") — not done as a side
> effect of adding the offsite-backup section below, which is genuinely current.
>
> **2026-08-22 update**: Sections E-H of the post-rebuild recovery effort landed today
> (see `phase8/LEDGER.md` Entries 84-92 for full detail, `docs/decisions/ADR-026-
> three-vm-topology-overhead.md` for the newest ADR). Real state, not reflected
> anywhere below since this table predates it: external blackbox monitoring (44
> hostnames) + weekly Discord report + dead man's switch built; a 37h+ Prometheus
> outage found and fixed; NVMe SMART wear tracking built, with a genuinely urgent
> finding — the boot drive is at 56% rated wear and climbing (`docs/HARDWARE.md`,
> "SSD wear tracking"), with a documented write-rate-reduction pass in response
> (swappiness, trivy-operator concurrency) since the operator chose not to replace it;
> RAPL CPU power metrics wired up, with a found-but-not-yet-applied `amd_pstate=active`
> fix pending an operator-approved reboot; Kyverno redeployed and re-enforced
> (namespace-by-namespace, after a real load incident mid-rollout — see ADR-023's
> 2026-08-22 update); Pod Security Standards + NetworkPolicy egress + default-SA
> automount hardening added; a real fix for metallb's FRR sidecar, which had been
> crash-looping ~1000+ times per pod for a completely unused BGP mode. Grafana
> curated with one real landing dashboard. Several of these landed via direct
> `kubectl`/`ansible-playbook` application and are pushed as open PRs awaiting
> merge — check `git log --all --oneline` and open PRs for what's merged vs. still
> pending, don't assume this file or even the live cluster fully reflects git yet.
>
> **2026-08-23 update — recovery mission substantially complete.** Every branch from
> this and the prior session merged to main; `gh auth` works on this box now (the
> earlier blocker on "everything merged to main" is gone). Closed out since the
> 2026-08-22 note above: `amd_pstate=active` reboot executed by the operator and
> verified live (`scaling_driver: amd-pstate-epp`) — found and fixed a real follow-on
> bug the reboot exposed (the configured CPU governor, `schedutil`, isn't offered
> under active mode at all; `docs/HARDWARE.md`'s Power section has the full story).
> Kyverno/NetworkPolicy hardening now covers every namespace including `apps` (the
> last deferred one — real per-workload traffic map, not a blanket rule). A
> declared-vs-live drift guard now runs every 30 minutes (`docs/decisions/
> ADR-027-declared-vs-live-drift-guard.md`) after this exact failure class (a
> manifest merged to git, never actually applied) bit the dead man's switch itself.
> The Ansible Vault plaintext-decrypt exposure class is closed (per-key encryption)
> and the standing Vault root token is gone (see `DISASTER-RECOVERY.md`'s "Standing
> root token" section for the replacement procedure). See `docs/STEADY-STATE.md` for
> what the cluster now does on its own vs. what still needs a human, going forward —
> that document, not this roadmap, is the current source of truth for day-to-day
> operation. **Still genuinely open**, not closed by this update: the
> `fwd_04a_srv_monitoring` MikroTik/Terraform-state gap blocking `node-exporter-pve`
> from reaching Prometheus (blocks NVMe wear alerts and host power/thermal metrics
> from actually firing — trigger: fix whenever someone has real MikroTik/Terraform
> state-import time, tracked as a real gap, not urgent-critical); CIS kubelet
> file-permission findings (4.1.3-4.1.8) needing SSH access to the k3s VMs this
> agent doesn't have; a cluster-admin/wildcard RBAC audit (CIS 5.1.1/5.1.3) needing
> dedicated time; the SSD wear trigger itself (`docs/HARDWARE.md` — check monthly,
> real replace-now trigger at 90% used or any media error).

## Offsite backup provider (2026-08-17, BRIEFING-V4.md Phase 3)

**Decision needed from the operator — this is the one item in the whole backup plan
that needs a card.** Everything else (Vault snapshots, Proxmox host config backup,
automated restore verification) is being built regardless of this choice, so it's
ready to point at whichever provider gets picked.

**Real current volume** (checked live, not estimated): Garage's total object storage
is **51.9 GiB** across 5 buckets (`velero`, `cnpg-backups`, `loki-data`,
`terraform-state`, `pve-host-config` — the last one new as of this same pass). This is
what actually needs an offsite mirror. Immich's real photo library is **76 GiB**
(`du -sh` on the live PVC, matching this brief's own cited figure almost exactly) but
is *deliberately excluded* from Velero backup already (`kubernetes/apps/immich/
immich.yml`'s `backup.velero.io/backup-volumes-excludes: library` annotation, reasoning
given inline: "large cold storage, not worth backing up as a filesystem blob (re-upload
source from phone)") — a real, prior, deliberate trade-off, not an oversight this
roadmap item is meant to silently reopen. Sizing below assumes **~150 GiB** as a
reasonable multi-year growth allowance over the current 52 GiB, not the raw current
number.

| Provider | Storage cost (150GB) | Egress | Object Lock (WORM) | S3-compatible | Notes |
|---|---|---|---|---|---|
| **Backblaze B2** (recommended) | ~$1.04/mo (\$0.00695/GB) | Free up to 3x stored data/mo, then \$0.01/GB | **Confirmed GA, free, no extra cost** | Yes | First 10GB always free. 3x-stored-data free egress easily covers a monthly restore-verification pull of the whole dataset. |
| Cloudflare R2 | ~$2.25/mo (\$0.015/GB) | Free, unlimited | Not confirmed available at time of this research (couldn't find current docs confirming GA status) | Yes | 2x B2's storage cost; egress advantage doesn't matter much at this volume since B2's free-egress allowance already covers it. Would need Object Lock support confirmed with Cloudflare directly before committing. |
| Hetzner Storage Box | Smallest tier (BX11, 1TB) — real price not confirmed in this research pass, historically ~€4/mo | Not S3-compatible — SFTP/SCP/RSYNC/WebDAV only | **Not supported** (Storage Box has snapshots, not true immutability; Hetzner's *separate* S3-compatible Object Storage product wasn't evaluated for this) | No (Storage Box specifically) | Ruled out primarily on the missing Object Lock requirement — this brief is explicit that "the host must not hold credentials capable of destroying the remote copy," which Object Lock satisfies directly and snapshots alone don't (a credential with delete rights can still delete the snapshots). |
| rsync.net | 800GB **minimum order** — ~$12/mo even though only ~150GB would be used | Free (no egress charges) | ZFS snapshots + restricted-shell/append-only configurations (well-regarded in the backup community), not confirmed as a formal S3 Object Lock equivalent | Not natively (SFTP/rsync; some accounts offer S3 gateway) | Excellent reputation for ransomware-resistant backups, but the 800GB minimum means paying for ~5x the actual need at this scale — worth reconsidering if this dataset grows past a few hundred GB. |

**Recommendation: Backblaze B2.** Confirmed, free, GA Object Lock is the deciding
factor — it's the one requirement (`BRIEFING-V4.md`: "a runaway agent with root here
must not be able to reach it") none of the alternatives clearly satisfy at this price
point. S3-compatible, so `rclone`/Velero's existing S3 tooling (already used for
Garage) needs no new integration work. Real monthly cost at current+growth volume:
**roughly $1-2/month**, plus $0 practical egress cost given the free-tier allowance
comfortably covers a monthly full-dataset restore-verification pull.

**Trigger condition**: revisit if the real dataset grows past ~500GB (at which point
rsync.net's per-GB rate advantage starts to outweigh its minimum-order overhead) or if
Cloudflare R2's Object Lock status gets confirmed GA and its free unlimited egress
becomes more valuable than it currently is at this volume.

**What's needed to activate**: a Backblaze account + a B2 Application Key scoped to a
new bucket, Object Lock enabled at bucket creation (cannot be added after the fact per
B2's own docs) with a governance-mode retention period (recommend 35 days — covers the
existing 30-day local retention pattern already used for `pve-host-config` plus a
margin). Once the operator provisions the account, this agent can build the actual
sync job (same `rclone`-based pattern already proven for `pve-host-config`) without
further input.

**Note on existing R2 scaffolding**: `kubernetes/system/velero/r2-backuplocation.yml`
and `offsite-schedule.yml` already exist in the repo from a prior, incomplete attempt —
checked live, they are **not** half-built infra ready to flip on. `velero-manifests`'
ArgoCD Application explicitly excludes both (`include: '{secrets,schedule}.yml'`, with
an inline comment dated 2026-06-25, WRK-008: "scaffolded but incomplete, literal
ACCOUNT_ID placeholder, credential secret doesn't exist anywhere... confirmed live that
including them creates an Unavailable BackupStorageLocation and a Schedule that would
fail daily at 4am"). Confirmed still true right now: only the `default` BSL exists
live, no `r2-offsite` BSL, no `velero-r2-credentials` Secret. If B2 gets picked per the
recommendation above, these two R2 files should be deleted (not adapted — Velero's AWS
plugin works fine against B2's S3-compatible endpoint too, but reusing R2-named files
for a different provider is more confusing than starting clean) as part of building the
real schedule.

**Resolved, 2026-08-23**: the operator went with **R2**, not the B2 recommendation
above — real, working divergence, not an oversight to "correct" back to B2. Confirmed
live: `BackupStorageLocation/r2-offsite` and `Schedule/daily-offsite` both exist and
are genuinely applied (PR #512 built a dedicated `r2-usage-guard` CronJob specifically
to pause offsite backup before hitting R2's free-tier cap — the actual mechanism this
section worried B2 vs. R2 wouldn't need). Leaving the B2 analysis above as real,
still-useful research (the Object Lock/pricing comparison holds regardless of which
was picked) rather than deleting it, but this item itself is closed — no decision
still pending.

## Planned Services

### Deployed

| Service | URL | Notes |
|---|---|---|
| **Renovate Bot** | — | CronJob, every 2h. GitHub PAT already applied (`renovate-token` secret in `apps`). Config had an invalid preset (`:enableHelpfulPre-commit`, not a real Renovate preset) causing every run to fail config validation silently — fixed 2026-06-23. |
| **Mealie** | mealie.woitzik.dev | SQLite, 5Gi PVC (`local-path`), Authelia-protected |
| **Nextcloud** | nextcloud.woitzik.dev | PostgreSQL + Redis, 20Gi PVC |
| **Home Assistant** | ha.woitzik.dev | IP-based integrations, 5Gi PVC (`local-path`) |
| **Jellyfin** | media.woitzik.dev | Runs on its own dedicated LXC (`ct_srv_jellyfin_01`, direct NFS media mount), not in k3s — `kubernetes/apps/jellyfin/` is just an external-service pointer for Traefik. Hardware transcode via VAAPI (`/dev/dri/renderD128` passthrough), replacing an earlier software-only k3s Deployment. |
| **SABnzbd** | sabnzbd.woitzik.dev | Usenet downloader, Authelia-protected |
| **Sonarr** | sonarr.woitzik.dev | TV automation, Authelia-protected |
| **Radarr** | radarr.woitzik.dev | Movie automation, Authelia-protected |
| **Bazarr** | bazarr.woitzik.dev | Subtitle management, Authelia-protected |
| **Authelia** | auth.woitzik.dev | SSO/OIDC, 2 replicas, CNPG Postgres + Redis backend |
| **ArgoCD** | argo.woitzik.dev | GitOps — `kubernetes/apps/*` ApplicationSet + manual `kubernetes/system/*` Applications |
| **Atlantis** | atlantis.woitzik.dev | Terraform GitOps for MikroTik + Proxmox, exposed via Cloudflare Tunnel |
| **Gitea** | git.woitzik.dev | Private git for the Azure modules |
| **Vaultwarden** | vault.woitzik.dev | Password manager |
| **HashiCorp Vault** | secrets.woitzik.dev | Secrets backend for ESO, auto-unseal active |
| **Garage S3** | s3.woitzik.dev | S3-compatible object storage — Velero + Terraform state backend |
| **Headscale** | headscale.woitzik.dev | Self-hosted Tailscale control plane, OIDC login via Authelia |
| **Open WebUI** | ai.woitzik.dev | LLM frontend for Ollama (AI LXC) |
| **Uptime Kuma** | status.woitzik.dev | Service uptime monitoring, 25 monitors |
| **Paperless-ngx + paperless-gpt** | docs.woitzik.dev | Document management. `LLM_MODEL=qwen2.5-coder:7b` for text tagging. `VISION_LLM_MODEL` was briefly misconfigured to the same non-vision model, which silently hallucinated OCR content for image-based documents instead of erroring — fixed, now points at an actual vision-capable model. |
| **Jellyseerr** | requests.woitzik.dev | Movie/TV requests, linked to Radarr/Sonarr |
| **NZBHydra2** | — | Usenet indexer meta-search |
| **Homepage** | woitzik.dev (root) | Dashboard with live widgets (ArgoCD, Traefik, Uptime Kuma, Grafana, *arr stack) |
| **Grafana / Prometheus / Loki / Tempo** | monitoring.woitzik.dev | LGTM stack complete, SLOs + error-budget dashboard |

### Pending (requires 4TB SSD)

| Service | Namespace | Description |
|---|---|---|
| **Navidrome** | `apps` | Music streaming (Subsonic-compatible) |

### Pending (storage planned)

| Service | Namespace | Description |
|---|---|---|
| **Immich** | `apps` | Self-hosted Google Photos — ML face recognition, mobile backup. Storage split: original/thumbnail files on a 512GB USB stick (`usb-immich-photos`, ext4, `noatime`) — read-mostly workload, fine for flash endurance. Postgres DB (metadata, face-recognition vectors) stays on the existing NFS/SSD storage, not the stick. No SMART monitoring on the stick expected; treat as a higher-risk volume, same caveat as the existing unbacked `media` PVC. **Not deployed yet** — confirmed 2026-06-23, no k8s resources or manifests exist for it. |

### In Progress

| Service | Status | Notes |
|---|---|---|
| **NFS Storage Migration** | ✅ Done | All PVCs migrated to `storageClassName: nfs-client` or `local-path` (SQLite/BoltDB apps stay on `local-path` — file-locking semantics don't tolerate NFS well). Longhorn removed. NFS server: `ct-srv-nfs-01` (10.0.20.100, VMID 220). |
| **Jellyfin GPU passthrough** | 🔄 Planned | Move Jellyfin to its own GPU-passthrough LXC (same pattern as the AI LXC) for real VAAPI hardware transcoding — confirmed 2026-06-23 the iGPU's video encode/decode block is healthy (`vainfo` + a real `ffmpeg` hwaccel encode both passed), it's just never been wired up for Jellyfin. Proxmox iGPU passthrough is exclusive, so this needs its own LXC rather than sharing with the AI LXC. |

### Pending (other)

| Service | Notes |
|---|---|
| **Claude Code Web Terminal** | PR #38 was closed, not merged — abandoned, not actually in progress. No Terraform/Ansible artifacts exist for it (`ct-srv-claude-01` was never created). If revisited: new LXC, `ttyd` + Claude Code CLI, `claude.woitzik.dev` (Authelia-protected), Anthropic API key or OAuth login. |
| **Uptime Kuma Monitors** | WebSocket API setup required via the web UI at status.woitzik.dev — script `ansible/add_kuma_monitors.py` is ready, needs an API token from the Kuma UI. |
| **Paperless → Nextcloud consume** | Mount a Nextcloud shared folder as Paperless's consume PVC: Nextcloud External Storage app → local filesystem, then mount that as an NFS PV in k3s for Paperless's `consume` directory. Alternative: Paperless WebDAV-consume directly against Nextcloud's WebDAV endpoint. |
| **Remote Dev Environment (code-server)** | VS Code Server on k3s — `coder/code-server` (pinned digest, not `:latest`) as a k8s Deployment, 2Gi PVC for workspace, Authelia-protected IngressRoute. Needs resource limits (Kyverno enforces this now). |
| **MySpeed** | Self-hosted internet speedtest history (`ghcr.io/germannewsmaker/myspeed`), new app under `kubernetes/apps/myspeed/` following the established pattern (Deployment + Service + PVC + IngressRoute, Authelia-protected). |

---

## Infrastructure Improvements (Impressiveness Tier)

These items directly signal DevOps/Cloud maturity to employers and interviewers.

### Tier 1 — High Impact (do next)

| Item | Why it matters |
|---|---|
| ~~**External Secrets Operator + HashiCorp Vault**~~ ✅ | ESO 0.10.3 + Vault 0.28.1 deployed — ClusterSecretStore backed by Vault KV v2 |
| ~~**Kyverno policy engine**~~ ✅ | `require-resource-limits` and `disallow-latest-tag` both flipped to **Enforce** 2026-06-23 (were Audit-only); `disallow-privileged-containers` already Enforce |
| ~~**Grafana Tempo**~~ ✅ | Tempo deployed, linked to Loki (trace→log correlation) and Prometheus (service map). LGTM stack complete. |
| ~~**Renovate GitHub PAT**~~ ✅ | Token already applied (`renovate-token` secret, `apps` namespace) — fixed the invalid-preset bug blocking it from actually doing anything (2026-06-23). |
| ~~**Authelia OIDC `hmac_secret` in Vault**~~ ✅ | `hmac_secret` removed from the ConfigMap, stored in Vault KV v2 under `secret/authelia`. ExternalSecret with `creationPolicy: Merge` syncs the key into `authelia-secrets`. ConfigMap references `/config/secrets/hmac-secret`. |
| ~~**Authelia scaled to 2 replicas**~~ ✅ | Deployment at `replicas: 2`. PDB (`minAvailable: 1`) already existed. Redis session store + CNPG backend were ready. |

### Tier 2 — Solid Engineering

| Item | Why it matters |
|---|---|
| ~~**CloudNativePG operator**~~ ✅ | CNPG 0.23.0 deployed; `postgres-authelia` migrated from a bare StatefulSet. WAL archiving to Garage S3, PodMonitor + Grafana dashboard, plus a daily `ScheduledBackup` for a full base backup. |
| ~~**Trivy in CI**~~ ✅ | `aquasecurity/trivy-action` in GitHub Actions — misconfig scan + SARIF to the GitHub Security tab |
| ~~**PodDisruptionBudgets**~~ ✅ | PDBs for Authelia (2 replicas), cloudflared (2 replicas), Vaultwarden, Nextcloud, Home Assistant |
| ~~**Chaos Mesh**~~ ✅ | Weekly schedules: pod-kill Sunday 03:00 UTC + 100ms network latency Sunday 03:30 UTC on labelled `apps` namespace pods |
| ~~**SLO definitions**~~ ✅ | PrometheusRules deployed: 99.9% availability + p95≤2s latency SLOs with error-budget dashboard in Grafana. Blackbox exporter probing all public services. One real gotcha along the way: the rules were deployed but never actually evaluated for a while — a missing `release: kube-prometheus-stack` label meant Prometheus's `ruleSelector` never matched them. The same gap silently affected the hardware-temp alerts until caught. |

### Tier 3 — Nice to Have

| Item | Why it matters |
|---|---|
| ~~**Backup offsite → Cloudflare R2**~~ ✅ | Live — `daily-offsite` Velero Schedule confirmed `Enabled` with a recent successful backup (`kubectl get schedules.velero.io -n velero`). `r2-usage-guard` (`kubernetes/system/velero/r2-usage-guard.yml`) pauses it automatically before hitting R2's free-tier cap rather than risking a bill. Corrected here 2026-08-26 — this row previously said "not yet active," stale since the R2 credentials were actually wired in. |
| **Unify the IngressRoute convention** | Two patterns coexist: older apps route through the centralized `kubernetes/system/apps-ingressroute.yml`/`other-ingressroute.yml`; newer ones (`beszel`, `excalidraw`, `firefly`, `freshrss`, `gotify`, `linkding`, `lubelogger`, `matrix`, `myspeed`, `n8n`, `onlyoffice`, `searxng`) declare their own IngressRoute inline in their own directory instead. Both work today; picking one convention and migrating the rest is real but not urgent cleanup, found during the 2026-08-26 portfolio pass. |
| **k3s multi-master HA** | ❌ **Abandoned, not achieved** (corrected 2026-06-23 — this previously incorrectly showed ✅). 3-way embedded-etcd HA was tried and **reverted**: all 3 VMs share one physical host and ZFS pool, and 3 concurrent etcd writers caused repeated host freezes. Current state: `vm-srv-k3s-11` is the sole control-plane server (datastore is SQLite via kine, not etcd — see `docs/decisions/ADR-015-k3s-datastore-sqlite.md`), `-12`/`-13` are agent-only workers. This is deliberate, not a gap — see `docs/k3s-architecture.md` §1. The Keepalived VIP (`10.0.20.10`) still has stale failover priorities from the old design; not yet corrected. |
| **Cilium as CNI** | Replace default flannel with Cilium — enables eBPF-based NetworkPolicies, Hubble network observability UI, service mesh layer. **Caution**: a CNI swap requires a k3s reinstall or rolling replace — no live swap possible. |
| ~~**Unbound performance tuning**~~ ✅ | 4 threads, root hints, prefetch + prefetch-key, serve-expired, aggressive-nsec, cache-max-negative-ttl=300, 8MB socket buffers |
| ~~**Disaster Recovery runbook**~~ ✅ | `/DISASTER-RECOVERY.md` added 2026-06-23 (PR #59) — full rebuild (network → Proxmox → k3s → ArgoCD → Vault → Velero) plus per-service restore table. Not yet drilled end-to-end. |
| ~~**NetworkPolicies for the apps namespace**~~ ✅ | Default-deny + explicit allow deployed in `apps` and `monitoring` (`kubernetes/apps/network-policies.yml`, `kubernetes/system/monitoring/network-policies.yml`). 2026-06-19: the rollout silently broke two cross-namespace connections (Velero→Garage, Homepage→Uptime Kuma) — both only discovered days later via symptoms. Always check the NetworkPolicy files first when adding a new cross-namespace dependency. |
| ~~**Authelia health in Blackbox Exporter**~~ ✅ | `/api/health` added as a separate Prometheus job `blackbox-authelia-health`. Previously only the root redirect was probed — Traefik could return 200 while Authelia itself was down. Now the Authelia process is monitored directly. |
| ~~**Vault Auto-Unseal**~~ ✅ | `vault-unseal` Deployment polls every 5s (tightened from an initial 30s to close a window where a restarted Vault pod could sit sealed and cause a burst of failed secret syncs) and auto-unseals using keys from k8s Secret `vault-unseal-keys`. No manual intervention needed after a Vault restart. |
| ~~**Velero PVC data backup**~~ ✅ | **Critical finding 2026-06-19**: `daily-backup` was missing `defaultVolumesToFsBackup` — backups completed "successfully" but only captured k8s manifests, not real PVC data (Postgres, Vaultwarden, Paperless, Nextcloud). Fixed and verified with a test run (Kopia Pod Volume Backup). |

---

## Planned Hardware

### Short-term

- **512GB USB stick** (`usb-immich-photos`) — Immich original/thumbnail storage, see "Pending (storage planned)" above. Already available, not a future purchase.
- **4TB SSD** (M.2 NVMe or SATA) for the Proxmox host
  - Enables: Jellyfin media migration, Garage S3 expansion, Navidrome
  - Installation: straightforward, Proxmox auto-detects as a new datastore

### Long-term

- **Silent SSD NAS** (e.g. Synology DS223j or QNAP TS-233)
  - Bedroom placement — fanless, passively cooled
  - SMB/NFS share → direct k3s NFS mount
  - Use case: media library, photo archive, PBS backup target

---

## RAM Allocation (Proxmox Host — 64 GB)

| VM / LXC | Current | Notes |
|---|---|---|
| k3s-11 (control-plane) | **12 GB** (floating: 8–12) | sole etcd + control plane, no longer multi-master |
| k3s-12 (worker) | **16 GB** (floating: 8–16) | primary app workloads |
| k3s-13 (worker) | **16 GB** (floating: 8–16) | primary app workloads |
| AI LXC (Ollama) | 32 GB | LLM inference — CPU-only (the iGPU's Vulkan/radv fallback proved unstable under concurrent load, see the Ollama iGPU entry below) |
| Docker LXC | 4 GB | |
| NFS LXC | 2 GB (was 512MB, OOM'd once under concurrent multi-app backup/restore reads — raised, restore one app's data at a time going forward, see `DISASTER-RECOVERY.md`) | |
| PBS | 2 GB | |
| DMZ Proxy | 1 GB | |
| DMZ Games (Minecraft/Cobblemon) | 16 GB (was 12, raised to fix swap thrashing) | |
| **Total** | **~101 GB** | Floating/balloon enables overcommit beyond the host's 64GB physical |

The previous "Planned" RAM targets in this table have all been reached — RAM changes go through Terraform → Atlantis PR (`terraform/stacks/proxmox/vm.tf` / `lxc.tf`) as always.

---

## Monitoring Expansion (Completed)

- [x] Prometheus scrapes `node_exporter` from RPi-01, RPi-02, Docker LXC, AI LXC
- [x] `prometheus-pve-exporter` in monitoring namespace — Proxmox metrics in Grafana
- [x] Grafana dashboards: Proxmox (10347, 19022), Node Exporter Full (1860)
- [x] AlertManager → Discord webhooks (critical + warning routes, 12h repeat interval)
- [x] `node_exporter` confirmed running on all nodes

---

## Known Bugs / Blockers (historical log)

| Bug | Status | Root Cause |
|---|---|---|
| **IPv6 broken on FritzBox WiFi** | ✅ Fixed | RouterOS 7 sends RA on all interfaces by default, including ether1 (WAN). After ether1 got a GUA from the FritzBox via SLAAC, MikroTik started acting as an IPv6 gateway on the FritzBox LAN. WiFi clients routed IPv6 through MikroTik but got dropped by the FORWARD chain (only `fd00::/8` allowed). Fix: `routeros_ipv6_nd.ether1_no_ra` disables RA on ether1; NAT66 rule extended with `src_address = "fd00::/8"`. |
| **Authelia infinite redirect loop on auth.woitzik.dev** | ✅ Fixed | `access_control` rules in the wrong order: the `*.woitzik.dev → two_factor` catch-all was listed BEFORE `auth.woitzik.dev → bypass`. Authelia matches top-down, so the bypass rule was never reached → loop. Fix: moved `auth.woitzik.dev bypass` to the first rule. |
| **AdGuard restarted on every Ansible run** | ✅ Fixed | `docker_compose_v2: state: restarted` restarts the container on every playbook run regardless of changes. Fix: `state: present` + handler-based restart only on config change. |
| **AdGuard DNS overload on RPi** | ✅ Fixed | Combination of HaGeZi TIF (millions of entries) + OISD Full + 4MB cache + 300 goroutines + 90-day query log. Removed TIF + OISD (redundant with HaGeZi Pro), raised cache to 32MB, goroutines to 100, log retention to 7 days. |
| **Authelia `latest` image tag** | ✅ Fixed | `ghcr.io/authelia/authelia:latest` violated the Kyverno `disallow-latest-tag` policy. Pinned to `4.39.20`. |
| **k3s-12 NotReady (lost kubelet lease)** | ✅ Fixed | k3s-agent on k3s-12 lost its connection to the API server. `systemctl restart k3s-agent` on k3s-12 resolved it. |
| **Redis AOF I/O error → Authelia down** | ✅ Fixed | Redis AOF persistence failed with an I/O error after the k3s-12 cascade. Fix: `CONFIG SET appendonly no/yes` + `BGREWRITEAOF`. |
| **Jellyfin crash loop — inotify limit** | ✅ Fixed | `fs.inotify.max_user_instances=128` exhausted. Raised to 512 on all nodes, persisted via the Ansible common role. |
| **paperless-ai OOMKilled** | ✅ Fixed | Memory limit of 512Mi too low. Raised to 1536Mi, CPU limit to 500m. Image pinned to `2.8.2`. |
| **k3s-11 (control plane) intermittently unreachable** | ✅ Fixed | Load average 48–90 from app pods + Longhorn replicas + control plane all competing. Fix: tainted k3s-11 (`NoSchedule`), evacuated app workloads to k3s-12/13. Load dropped from 90 → 1.04. |
| **Garage SQLite corruption** | ✅ Recovered | Unclean shutdown from an OOM kill. `db.sqlite` pages 169–184 corrupted. Recovered via SQLite's `.recover` command; re-inserted the terraform-state bucket + Atlantis key via Python/msgpack directly into SQLite (Garage's format: `b'G2key'`/`b'G2bkt'` + msgpack dict, bucket_id as 32 bytes). Atlantis workflow switched from a broken filesystem-mirror approach to standard `init`/`plan`. |
| **Paperless OOMKilled (16x in 5h)** | ✅ Fixed | Tesseract+Tika OCR bursts exceeded the 1Gi limit, and it was scheduled onto the control-plane node due to a toleration. Fix: memory limit 1Gi→3Gi, CPU 500m→2000m, `TASK_WORKERS=2`, `THREADS=2`, removed the control-plane toleration. Now runs on `vm-srv-k3s-12`. |
| **AdGuard 1.58M DNS queries/day** | ✅ Fixed | CoreDNS TTL of 30s caused 1.2M queries. Fix: CoreDNS cache 30→300s (`kubectl patch`), AdGuard `cache_optimistic=true` + 64MB cache (Ansible). |
| **Homepage RAM negative (-250MiB, -1GiB)** | ✅ Fixed | Proxmox balloon minimum of 4096MB meant the balloon shrank to 3.8GB under host memory pressure. Fix: `floating=8192` for k3s-12/13 in `vm.tf`. |
| **Authelia schema mismatch (DB v24 vs image v15)** | ✅ Fixed | DB had schema v24 (written by v4.39.20), but the Deployment was running v4.38.18 (max schema v15). Fix: bumped image to `4.39.20`. |
| **k3s-12/k3s-13 workers only 3.8GB allocatable** | ✅ Fixed | Proxmox balloon minimum was 4096MB, so kubelet registered 3.8GB capacity at startup. Fix: set balloon to 16GB via the Proxmox API + `systemctl restart k3s-agent` on both nodes. Nodes now show `Capacity: memory: 16383272Ki` (16 GiB). |
| **Longhorn cross-node attach loop** | ✅ Resolved (migrated off Longhorn) | RWO volumes got attached to Node A during an OOM event, but the pod restarted on Node B → `Multi-Attach error`. Root cause: Longhorn isn't suited to a volatile single-host node environment. Fixed by migrating all PVCs from Longhorn to NFS (`ct-srv-nfs-01`). |
| **SABnzbd config PVC faulted** | 🟡 Data loss (historical) | Longhorn volume `pvc-6476c76f` faulted+detached after multiple node failures during the Longhorn era. Required a fresh start; a new NFS-backed PVC was created. |
| **Authelia at 2 replicas + health probe** | ✅ Fixed | Scaled to 2 replicas. Blackbox probe added on `/api/health`. |
| **NFS CT had the wrong naming scheme** | ✅ Fixed | The container was named `vm-srv-nfs-01` — should be `ct-srv-nfs-01` (LXC = `ct` prefix). Terraform resource + import added, tags set, hostname corrected on the container itself. |
| **Renovate silently failing every run** | ✅ Fixed (2026-06-24) | `renovate.json5` extended an invalid preset, `:enableHelpfulPre-commit` (not a real Renovate preset — likely a typo from whoever wrote the config). Every run hit a config-validation error and exited cleanly without ever checking for updates, so it looked "successful" in the CronJob's job history while doing nothing. Fixed the preset name and swapped the deprecated `config:base` for `config:recommended` (2026-06-23) — this got past config validation but then every run OOM'd (JS heap out of memory) against the 512Mi container limit, still failing silently the same way. Bumped to 1Gi limit + explicit `NODE_OPTIONS=--max-old-space-size=896` (2026-06-24). |
| **paperless-gpt hallucinating OCR content on every image document** | ✅ Fixed (2026-06-23) | `VISION_LLM_MODEL` was set to `qwen2.5-coder:7b`, a text-only model with no vision capability. paperless-gpt's "llm" OCR provider has no fallback mode — it sends the page image directly to this model and trusts whatever comes back, even though the model can't actually see the image. Result: plausible-looking but entirely fabricated German "OCR" text for several real documents, and correspondingly nonsense AI-generated titles. Fixed by switching to a real vision model (`minicpm-v`); affected documents need re-OCR, tracked separately. |
| **Ollama iGPU crashing under load (`vk::DeviceLostError`)** | ✅ Fixed (2026-06-23) | The AMD Barcelo iGPU (gfx90c) has no official ROCm support. The live config had drifted to a Vulkan/radv fallback (`OLLAMA_IGPU_ENABLE=1`) which crashed roughly once per inference call under any concurrent load (451 crashes in one day) — this is what was actually breaking paperless-gpt, not anything paperless-gpt itself did wrong. Fixed by switching Ollama to CPU-only. The originally-declared `HSA_OVERRIDE_GFX_VERSION=9.0.0` ROCm spoof in the Ansible role was never stable on this chip either, and nobody had reverted it — removed. |

---

## Notes

- Velero backups target Garage S3 (`velero` bucket on `s3.woitzik.dev`)
- Atlantis handles all Terraform changes — PRs only, never `terraform apply` locally
- MikroTik firewall: all rules are Terraform-managed — no manual RouterOS changes
- Authelia OIDC: ***REMOVED*** use `client_secret_basic`; ArgoCD uses `client_secret_post`
- Keel: requires the `keel.sh/policy` annotation on a Deployment to trigger auto-updates
- Renovate: GitHub PAT already applied via `renovate-token` secret (`apps` namespace) — not committed to git
