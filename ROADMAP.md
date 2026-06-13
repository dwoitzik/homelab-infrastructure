# Homelab Roadmap

## Planned Services

### Deployed

| Service | URL | Notes |
|---|---|---|
| **Renovate Bot** | — | CronJob, every 2h — apply GitHub PAT secret before first run |
| **Mealie** | mealie.woitzik.dev | SQLite, 5Gi PVC, Authelia-protected |
| **Nextcloud** | nextcloud.woitzik.dev | PostgreSQL + Redis, 20Gi PVC — apply secrets before first sync |
| **Gitea** | git.woitzik.dev | SQLite, 10Gi PVC — apply secrets before first sync |
| **Home Assistant** | ha.woitzik.dev | IP-based integrations, 5Gi PVC |

### Pending (requires 4TB SSD)

| Service | Namespace | Description |
|---|---|---|
| **Immich** | `apps` | Photo backup with ML face recognition |
| **Jellyfin** | `apps` | Media server for movies/series |
| **Navidrome** | `apps` | Music streaming |

### Pending (other)

| Service | Notes |
|---|---|
| **Uptime Kuma Monitors** | WebSocket API setup required via web UI at status.woitzik.dev |

---

## Planned Hardware

### Short-term

- **4TB SSD** (M.2 NVMe or SATA) for Proxmox host
  - Current: system drive only (local-zfs pool)
  - Goal: dedicated datastore for Immich photos, Jellyfin media, Garage S3
  - Installation: straightforward, Proxmox auto-detects

### Long-term

- **Silent SSD NAS** (e.g., Synology DS223j or QNAP TS-233)
  - Bedroom placement — fanless, passively cooled
  - SMB/NFS share → Longhorn external storage or direct k3s mount
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

RAM update submitted as Terraform change → Atlantis PR (`terraform/stacks/proxmox/vm.tf`).

---

## Monitoring Expansion (Completed)

- [x] Prometheus scrapes `node_exporter` from RPi-01, RPi-02, Docker LXC, AI LXC
- [x] `prometheus-pve-exporter` deployed in monitoring namespace
- [x] Proxmox API token `prometheus@pve!prometheus` created with `PVEAuditor` role
- [x] Grafana dashboards: Proxmox via Prometheus (10347, 19022), Node Exporter Full (1860)
- [ ] Run `ansible-playbook ansible/site.yml` to verify monitoring on all nodes

---

## Notes

- Velero backups target Garage S3 (`velero` bucket on `s3.woitzik.dev`)
- Atlantis handles all Terraform changes — PRs only, never `terraform apply` locally
- MikroTik firewall: all rules are Terraform-managed — no manual RouterOS changes
- Authelia OIDC: Proxmox/PBS/Grafana/Headscale use `client_secret_basic`; ArgoCD uses `client_secret_post`
