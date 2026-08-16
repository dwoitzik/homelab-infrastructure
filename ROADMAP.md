# Homelab Roadmap

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
| **Backup offsite → Cloudflare R2** | 🔄 Ready, not yet active — `kubernetes/system/velero/r2-backuplocation.yml` + `offsite-schedule.yml` committed (daily 04:00, TTL 7d, only apps/vault/database/argocd, large PVCs like `media` excluded by label). Waiting on a real Cloudflare R2 Account ID + API token from David. |
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
