# Homelab Audit — Gap Analysis & Deployment Tracker

Generated: 2026-07-20. Based on Reddit r/homelab, r/selfhosted consensus (2025/2026)
plus comparison against the 50+ essential self-hosted services lists.

## Current Stack (verified working)

| Category | Tool | Status |
|---|---|---|
| Hypervisor | Proxmox VE 9.2 | ✅ |
| Kubernetes | k3s v1.31.12 (3 nodes) | ✅ |
| GitOps | ArgoCD + Renovate | ✅ |
| Ingress | Traefik + cert-manager | ✅ |
| SSO | Authelia (CNPG + Redis) | ✅ |
| Secrets | Vault + External Secrets Operator | ✅ |
| Monitoring | Prometheus + Grafana + Loki + Tempo | ✅ |
| Uptime | Uptime Kuma (25 monitors) | ✅ |
| Host Monitor | Beszel | ✅ |
| Security | CrowdSec + Trivy + kube-bench + Kyverno | ✅ |
| Backups | Velero + Kopia + PBS | ✅ (offsite pending) |
| DNS | AdGuard Home + Unbound (RPis) | ✅ |
| VPN | Headscale (Tailscale) | ✅ |
| S3 | Garage | ✅ |
| DB | CloudNativePG (3 clusters) | ✅ |
| Media | Jellyfin (LXC) | ✅ |
| Photos | Immich | ✅ |
| Chat | Matrix/Synapse | ✅ |
| Files | Nextcloud | ✅ |
| Passwords | Vaultwarden | ✅ |
| Automation | n8n | ✅ |
| Dashboard | Homepage | ✅ |
| AI | Open-WebUI + Ollama | ✅ |
| Git | Gitea | ✅ |
| RSS | FreshRSS | ✅ |
| Bookmarks | Linkding | ✅ |
| Recipes | Mealie | ✅ |
| Docs | Paperless | ✅ |
| Whiteboard | Excalidraw | ✅ |
| Speedtest | MySpeed | ✅ |
| Notifications | Gotify | ✅ |
| Search | SearXNG | ✅ |
| Car Log | LubeLogger | ✅ |
| Home Auto | Home Assistant | ✅ |

## Pending Deployments

| Priority | Tool | Category | Status |
|---|---|---|---|
| ✅ | Scrutiny | Disk Health (S.M.A.R.T.) | ✅ Deployed |
| ✅ | OnlyOffice | Document Editing | ✅ Deployed |
| 🔴 P1 | Wazuh | SIEM | ❌ Decommissioned (2026-08-31, #649) -- 0 agents ever enrolled in 8 days, zero detection value, real resource cost. CrowdSec's sshd/nginx/linux collections on ct-dmz-proxy-01 fill the log-monitoring gap instead (#654/#656). |
| 🟡 P2 | Firefly III | Finance | ⏳ Pending |
| 🟡 P2 | Overseerr | Media Requests | ⏳ Pending |
| 🟡 P2 | Tautulli | Jellyfin Analytics | ⏳ Pending |

## Known Infrastructure Gaps

| ID | Gap | Impact | Status |
|---|---|---|---|
| REL-003 | Velero backs up into Garage (inside cluster) | Total cluster loss = no backups | Fixed -- `r2-offsite` BSL active for apps/argocd/database/vault, daily-offsite jobs completing |
| REL-012 | "etcd" apply latency under disk I/O | API Server outages | This cluster never ran etcd (ADR-015, kine/SQLite) -- root cause was an un-vacuumed `state.db` (623MB, 78% dead pages). Fixed 2026-08-31, `k3s_node_tuning` role now runs a monthly incremental vacuum |
| REL-073 | Garage meta (local-path) + data (nfs) different backends | Torn-state risk | Documented |
| — | No MikroTik remote syslog | Security events lost | Open |
| — | Kyverno excludes monitoring namespace | No policy enforcement on monitoring | Reviewed 2026-08-31: `disallow-privileged-containers` (the safety-critical one) already covers monitoring; `require-resource-limits`/`disallow-latest-tag` stay Audit-only there because upstream kube-prometheus-stack/Loki chart sidecars don't set resource limits by default -- correctly scoped, not a lazy gap |
| — | AUDIT.md referenced in code but missing | Stale references | Low priority |
| — | ct-dmz-proxy-01's CrowdSec had collections enabled but no working log source (`acquis.yaml` pointed at a nonexistent file, then rsyslog's ISO8601 default broke grok parsing) | Zero real sshd/nginx detection despite looking configured | Fixed 2026-08-31, #654/#656 |
| — | CNPG operator (`cnpg-system`) NotReady for 10+ hours, webhook endpoint empty, all 4 Postgres clusters' Backup creation blocked (`connection refused` to the webhook) | No new backups possible while down; found `postgres-authelia`'s backups had silently stopped since 2026-08-25 | Operator force-restarted 2026-08-31, webhook + backup creation confirmed working again |
| — | CNPG operator's periodic `/pg/status` health poll to instance pods (port 8000) gets instant `connection refused` for all 4 clusters -- instance-manager's actual health listener found bound to `127.0.0.1:8010`, not `0.0.0.0:8000` | `kubectl get cluster` status is stale/wrong ("Instance Status Extraction Error"); does NOT block backups (WAL archiving + on-demand/scheduled Backups confirmed working despite this) | Open -- found 2026-08-31, needs its own investigation (looks like a CNPG version/port mismatch, not urgent since actual backup/replication function is unaffected) |

## Deployment Log

### Scrutiny (S.M.A.R.T. disk monitoring)

- **Date**: 2026-07-20
- **Dir**: `kubernetes/apps/scrutiny/`
- **Image**: `ghcr.io/analogj/scrutiny:v0.9.2-web` (Web UI) + `ghcr.io/analogj/scrutiny:v0.9.2-collector` (Collector) + `influxdb:2.8`
- **Layout**: Hub/Spoke — InfluxDB StatefulSet + Web Deployment + Collector DaemonSet (3 nodes)
- **Storage**: nfs-client PVC (2Gi InfluxDB + 1Gi config)
- **IngressRoute**: scrutiny.woitzik.dev (CrowdSec + Authelia)
- **Notes**: Collector uses `hostPID: true` + `SYS_RAWIO` for smartctl. k3s containerd needs writable `/dev` mount + minimal securityContext (no seccompProfile, no drop ALL caps — collector image uses `su` internally). `system-manifests` stuck on resourceVersion conflicts for other IngressRoutes.

### OnlyOffice (Document Server)

- **Date**: 2026-07-20
- **Dir**: `kubernetes/apps/onlyoffice/`
- **Image**: `onlyoffice/documentserver:9.4` (bundled PG + Redis + Nginx)
- **Storage**: nfs-client PVC 10Gi
- **IngressRoute**: onlyoffice.woitzik.dev (CrowdSec + Authelia)
- **Memory**: 2.5GB limit — scheduled on k3s-13 via nodeAffinity
- **Integration**: Nextcloud connector requires JWT_SECRET + trusted domain config
- **Notes**: Bundled image is heavy (~1.5GB pull). Causes etcd instability when pulling on control plane nodes. Both etcd members crashed during pull → 5+ min outage. Consider pre-pulling large images.

### Wazuh (SIEM)

- **Date**: Pending
- **Notes**: Multi-component (manager, indexer, dashboard). Consider Docker Compose on ct-srv-docker-01 instead of k8s due to complexity.
