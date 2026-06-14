# Homelab Roadmap

## Planned Services

### Deployed

| Service | URL | Notes |
|---|---|---|
| **Renovate Bot** | — | CronJob, every 2h — apply GitHub PAT secret before first run |
| **Mealie** | mealie.woitzik.dev | SQLite, 5Gi PVC, Authelia-protected |
| **Nextcloud** | nextcloud.woitzik.dev | PostgreSQL + Redis, 20Gi PVC |
| **Home Assistant** | ha.woitzik.dev | IP-based integrations, 5Gi PVC |
| **Jellyfin** | media.woitzik.dev | NFS media PV (10.0.10.10:/mnt/media) |
| **SABnzbd** | sabnzbd.woitzik.dev | Usenet downloader, Authelia-protected |
| **Sonarr** | sonarr.woitzik.dev | TV automation, Authelia-protected |
| **Radarr** | radarr.woitzik.dev | Movie automation, Authelia-protected |
| **Bazarr** | bazarr.woitzik.dev | Subtitle management, Authelia-protected |

### Pending (requires 4TB SSD)

| Service | Namespace | Description |
|---|---|---|
| **Immich** | `apps` | Self-hosted Google Photos — ML face recognition, mobile backup |
| **Navidrome** | `apps` | Music streaming (Subsonic-compatible) |

### Pending (other)

| Service | Notes |
|---|---|
| **Uptime Kuma Monitors** | WebSocket API setup required via web UI at status.woitzik.dev |
| **NFS Server on Proxmox** | Required before Jellyfin goes live — share `/mnt/media` via NFS v4.2 |
| **Ollama GPU passthrough** | AMD Radeon iGPU → AI LXC via IOMMU — enables ROCm acceleration for paperless-ai |
| **Paperless → Nextcloud consume** | Mount Nextcloud shared folder as Paperless consume PVC |

---

## Infrastructure Improvements (Impressiveness Tier)

These items directly signal DevOps/Cloud maturity to employers and interviewers.

### Tier 1 — High Impact (do next)

| Item | Why it matters |
|---|---|
| **External Secrets Operator + Infisical** | Replace raw k8s Secrets with a pull-based secrets store. ESO is the industry standard for secrets management in k8s. Currently biggest gap vs. production-grade setups. |
| **Kyverno policy engine** | Policy-as-Code: block `latest` image tags in prod, require resource limits on all pods, deny privileged containers. Shows security-first mindset. |
| **Grafana Tempo** | Completes the LGTM observability stack (Loki + Grafana + Tempo + Mimir). Distributed tracing is the missing piece — metrics and logs are already done. |
| **Renovate GitHub PAT** | Apply the actual token so Renovate creates digest-pinning PRs — links the GitOps loop closed for image updates. |

### Tier 2 — Solid Engineering

| Item | Why it matters |
|---|---|
| **CloudNativePG operator** | Replace bare postgres StatefulSet with a Kubernetes-native operator. Shows operator pattern knowledge, gives automated failover, PITR backups. |
| **Trivy in CI** | Add `aquasecurity/trivy-action` to GitHub Actions — scans container images for CVEs on every PR. Signals security-in-CI awareness. |
| **PodDisruptionBudgets** | Add PDBs for Authelia, Vaultwarden, Nextcloud — prevents drain-caused downtime. Shows HA operational thinking. |
| **Chaos Mesh** | Scheduled fault injection (pod kill, network partition) — validates the alerting and recovery path. Impressive for SRE roles. |
| **SLO definitions** | Define Prometheus recording rules + Grafana dashboards for error budget / SLO burn rate on key services (Authelia, Vaultwarden, Nextcloud). |

### Tier 3 — Nice to Have

| Item | Why it matters |
|---|---|
| **Backup offsite → Oracle Cloud S3** | Velero daily snapshot of critical PVCs (Paperless, Vaultwarden, Nextcloud) pushed to Oracle Cloud free-tier 20GB bucket. |
| **k3s multi-master HA** | Add a second control plane node — etcd goes from single-point to quorum. Currently 1 master + 2 workers. |
| **Cilium as CNI** | Replace default flannel with Cilium — enables eBPF-based NetworkPolicies, Hubble network observability UI, service mesh layer. |
| **Unbound performance tuning** | Increase to 4 threads, add root-hints file, tune cache-max-negative-ttl and prefetch. |
| **Disaster Recovery runbook** | Step-by-step doc: how to rebuild from zero (Proxmox → k3s → ArgoCD bootstrap → secrets inject). Interviewers love seeing this. |

---

## Planned Hardware

### Short-term

- **4TB SSD** (M.2 NVMe or SATA) for Proxmox host
  - Enables: Immich photo library, Jellyfin media migration, Garage S3 expansion
  - Installation: straightforward, Proxmox auto-detects as new datastore

### Long-term

- **Silent SSD NAS** (e.g., Synology DS223j or QNAP TS-233)
  - Bedroom placement — fanless, passively cooled
  - SMB/NFS share → direct k3s NFS mount
  - Use case: media library, photo archive, PBS backup target

---

## RAM Allocation (Proxmox Host — 64 GB)

| VM / LXC | Current | Planned | Notes |
|---|---|---|---|
| k3s-11 (master) | 8 GB | **12 GB** (balloon: 4–12) | etcd + control plane overhead |
| k3s-12 (worker) | 8 GB | **16 GB** (balloon: 4–16) | primary app workloads |
| k3s-13 (worker) | 8 GB | **16 GB** (balloon: 4–16) | primary app workloads |
| AI LXC (Ollama) | 32 GB | 32 GB | LLM inference |
| Docker LXC | 4 GB | 4 GB | |
| PBS | 2 GB | 2 GB | |
| DMZ Proxy | 1 GB | 1 GB | |
| DMZ Games | 4 GB | 4 GB | |
| **Total static** | **67 GB** | **87 GB** | Balloon enables overcommit |

RAM update: submit as Terraform change → Atlantis PR (`terraform/stacks/proxmox/vm.tf`).

---

## Monitoring Expansion (Completed)

- [x] Prometheus scrapes `node_exporter` from RPi-01, RPi-02, Docker LXC, AI LXC
- [x] `prometheus-pve-exporter` in monitoring namespace — Proxmox metrics in Grafana
- [x] Grafana dashboards: Proxmox (10347, 19022), Node Exporter Full (1860)
- [x] AlertManager → Discord webhooks (critical + warning routes, 12h repeat interval)
- [ ] Run `ansible-playbook ansible/site.yml` to verify node_exporter on all nodes

---

## Notes

- Velero backups target Garage S3 (`velero` bucket on `s3.woitzik.dev`)
- Atlantis handles all Terraform changes — PRs only, never `terraform apply` locally
- MikroTik firewall: all rules are Terraform-managed — no manual RouterOS changes
- Authelia OIDC: Proxmox/PBS/Grafana/Headscale use `client_secret_basic`; ArgoCD uses `client_secret_post`
- Keel: requires `keel.sh/policy` annotation on Deployments to trigger auto-updates
- Renovate: requires GitHub PAT applied via `kubectl create secret` — token is NOT committed
