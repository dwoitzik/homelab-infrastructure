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
| 🔴 P1 | Wazuh | SIEM | ⏳ Pending |
| 🟡 P2 | Firefly III | Finance | ⏳ Pending |
| 🟡 P2 | Overseerr | Media Requests | ⏳ Pending |
| 🟡 P2 | Tautulli | Jellyfin Analytics | ⏳ Pending |

## Known Infrastructure Gaps

| ID | Gap | Impact | Status |
|---|---|---|---|
| REL-003 | Velero backs up into Garage (inside cluster) | Total cluster loss = no backups | Scaffolded R2 offsite, not active |
| REL-012 | etcd apply latency under disk I/O | API Server outages | Monitoring in place |
| REL-073 | Garage meta (local-path) + data (nfs) different backends | Torn-state risk | Documented |
| — | No MikroTik remote syslog | Security events lost | Open |
| — | Kyverno excludes monitoring namespace | No policy enforcement on monitoring | Workaround |
| — | AUDIT.md referenced in code but missing | Stale references | Low priority |

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
