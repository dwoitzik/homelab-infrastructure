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
| **Uptime Kuma Monitors** | WebSocket API setup required via web UI at status.woitzik.dev — Script `ansible/add_kuma_monitors.py` liegt bereit, benötigt API-Token aus Kuma UI. |
| **NFS Server on Proxmox** | Required before Jellyfin goes live — share `/mnt/media` via NFS v4.2 auf `10.0.10.10`. Proxmox Host selbst als NFS-Server (kein extra LXC nötig): `apt install nfs-kernel-server`, Export `/mnt/media 10.0.20.0/24(ro,no_root_squash)`. |
| **Ollama GPU passthrough** | AMD Radeon iGPU → AI LXC via IOMMU — enables ROCm acceleration for paperless-ai. Proxmox: IOMMU in Grub aktivieren (`amd_iommu=on iommu=pt`), LXC Device-Mapping für `/dev/dri`. Ollama benötigt ROCm-fähiges Image (`ollama/ollama:rocm`). |
| **Paperless → Nextcloud consume** | Mount Nextcloud shared folder als Paperless consume PVC: Nextcloud External Storage App → lokales Filesystem, dann NFS-PV in k3s für Paperless `consume` mounten. Alternativ: Paperless WebDAV-Consume direkt auf Nextcloud-WebDAV. |
| **Remote Dev Environment (code-server)** | VS Code Server auf k3s — `coder/code-server:latest` als k8s Deployment, 2Gi PVC für Workspace, Authelia-geschütztes IngressRoute. Benötigt: gepinntes Image, ResourceLimits (Kyverno), PVC mit ReadWriteOnce. Alternativ: Headscale-Client auf Mobile + SSH+tmux gegen Docker LXC. |

---

## Infrastructure Improvements (Impressiveness Tier)

These items directly signal DevOps/Cloud maturity to employers and interviewers.

### Tier 1 — High Impact (do next)

| Item | Why it matters |
|---|---|
| ~~**External Secrets Operator + HashiCorp Vault**~~ ✅ | ESO 0.10.3 + Vault 0.28.1 deployed — ClusterSecretStore backed by Vault KV v2 |
| ~~**Kyverno policy engine**~~ ✅ | Three ClusterPolicies deployed: require-resource-limits (Audit), disallow-privileged (Enforce), disallow-latest-tag (Audit) |
| ~~**Grafana Tempo**~~ ✅ | Tempo deployed, linked to Loki (trace→log correlation) and Prometheus (service map). LGTM stack complete. |
| **Renovate GitHub PAT** | Apply the actual token so Renovate creates digest-pinning PRs — links the GitOps loop closed for image updates. `kubectl create secret generic renovate-secret --from-literal=token=<PAT> -n system` — token must have `repo` + `read:packages` scopes. |
| **Authelia OIDC `hmac_secret` in Vault** | `hmac_secret` ist aktuell Plaintext in der ConfigMap. In Vault KV v2 unter `secret/authelia/oidc` ablegen, ExternalSecret anlegen, in configmap als Datei-Referenz einbinden (`/config/secrets/hmac-secret`). |
| ~~**Authelia auf 2 Replicas skalieren**~~ ✅ | Deployment auf `replicas: 2` erhöht. PDB (`minAvailable: 1`) existierte bereits. Redis-Session-Store + CNPG-Backend waren ready. |

### Tier 2 — Solid Engineering

| Item | Why it matters |
|---|---|
| ~~**CloudNativePG operator**~~ ✅ | CNPG 0.23.0 deployed; postgres-authelia migrated from bare StatefulSet. WAL archiving to Garage S3, 7-day PITR, PodMonitor + Grafana dashboard. |
| ~~**Trivy in CI**~~ ✅ | `aquasecurity/trivy-action` in GitHub Actions — misconfig scan + SARIF to GitHub Security tab |
| ~~**PodDisruptionBudgets**~~ ✅ | PDBs for Authelia (2 replicas), cloudflared (2 replicas), Vaultwarden, Nextcloud, Home Assistant |
| ~~**Chaos Mesh**~~ ✅ | Weekly schedules: pod-kill Sunday 03:00 UTC + 100ms network latency Sunday 03:30 UTC on labelled apps namespace pods. |
| ~~**SLO definitions**~~ ✅ | PrometheusRules deployed: 99.9% availability + p95≤2s latency SLOs with error budget dashboard in Grafana. Blackbox exporter probing all public services. |

### Tier 3 — Nice to Have

| Item | Why it matters |
|---|---|
| **Backup offsite → Oracle Cloud S3** | Velero daily snapshot of critical PVCs (Paperless, Vaultwarden, Nextcloud) pushed to Oracle Cloud free-tier 20GB bucket. Velero bereits deployed, Garage S3 als primäres Target. Oracle als zweites Ziel per `BackupStorageLocation`. |
| **k3s multi-master HA** | Add a second control plane node — etcd goes from single-point to quorum. Currently 1 master + 2 workers. Proxmox VM klonen, k3s-cluster Ansible-Playbook mit `--server` Flag joinen. Atlantis PR für Proxmox VM-Definition. |
| **Cilium as CNI** | Replace default flannel with Cilium — enables eBPF-based NetworkPolicies, Hubble network observability UI, service mesh layer. **Achtung**: CNI-Wechsel erfordert k3s Neuinstallation oder Rolling-Replace — kein Live-Swap möglich. |
| ~~**Unbound performance tuning**~~ ✅ | 4 threads, root-hints, prefetch + prefetch-key, serve-expired, aggressive-nsec, cache-max-negative-ttl=300, 8MB socket buffers. |
| **Disaster Recovery runbook** | Step-by-step doc: how to rebuild from zero (Proxmox → k3s → ArgoCD bootstrap → secrets inject from Vault). Ablegen unter `docs/disaster-recovery.md`. Interviewers love seeing this. |
| **NetworkPolicies für apps namespace** | Kyverno kann Policies enforzen, aber konkrete NetworkPolicy-Manifeste fehlen noch. Jedes Deployment sollte nur mit seinen direkten Backends kommunizieren dürfen (egress whitelist). Besonders Authelia → Redis/PostgreSQL only. |
| ~~**Authelia-Health in Blackbox Exporter**~~ ✅ | `/api/health` Endpoint ergänzt als separater Prometheus-Job `blackbox-authelia-health`. Vorher wurde nur der Root-Redirect geprobt — Traefik konnte 200 liefern während Authelia down war. Jetzt wird der Authelia-Prozess direkt überwacht. |

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

## Known Bugs / Blockers

| Bug | Status | Root Cause |
|---|---|---|
| **IPv6 broken auf FritzBox WiFi** | ✅ Fix committed | RouterOS 7 sendet standardmäßig RA auf ALLEN Interfaces inkl. ether1 (WAN). Nachdem ether1 via SLAAC eine GUA vom FritzBox erhielt, trat MikroTik als IPv6-Gateway auf dem FritzBox-LAN auf. WLAN-Clients routeten IPv6 über MikroTik, wurden aber vom FORWARD chain gedropt (nur `fd00::/8` erlaubt). Fix: `routeros_ipv6_nd.ether1_no_ra` deaktiviert RA auf ether1. NAT66-Regel um `src_address = "fd00::/8"` ergänzt. |
| **Authelia Infinite Redirect Loop auf auth.woitzik.dev** | ✅ Fix committed | `access_control`-Regeln in falscher Reihenfolge: `*.woitzik.dev → two_factor` Catch-All stand VOR `auth.woitzik.dev → bypass`. Authelia matcht top-down, bypass-Regel wurde nie erreicht → Loop. Fix: `auth.woitzik.dev bypass` als erste Regel. |
| **AdGuard immer neugestartet bei Ansible-Run** | ✅ Fix committed | `docker_compose_v2: state: restarted` startet Container bei JEDEM Playbook-Run neu, unabhängig von Änderungen. Fix: `state: present` + Handler-basierter Restart nur bei Config-Änderung. |
| **AdGuard DNS Überlast auf RPi** | ✅ Fix committed | Kombination aus HaGeZi TIF (Millionen Einträge) + OISD Full + 4MB Cache + 300 goroutines + 90-Tage Query-Log. TIF + OISD entfernt (redundant zu HaGeZi Pro), Cache auf 32MB erhöht, goroutines auf 100, Log-Retention auf 7 Tage. |
| **Authelia `latest` Image-Tag** | ✅ Fix committed | `ghcr.io/authelia/authelia:latest` verletzt Kyverno-Policy `disallow-latest-tag`. Gepinnt auf `4.38.18`. |
| **k3s-12 NotReady (kubelet Lease verloren)** | ✅ Fix live | k3s-agent auf k3s-12 hatte Verbindungsabbruch zur API-Server. `systemctl restart k3s-agent` auf k3s-12 behoben. Root cause: unbekannt, möglicherweise transient. Monitoring: AlertManager sollte NodeNotReady binnen 5min alerten. |
| **k3s-13 kubectl exec/logs 502** | ✅ Fix live | Kubelet-Proxy auf k3s-13 nach k3s-12-Ausfall beschädigt. `systemctl restart k3s-agent` auf k3s-13 behoben. |
| **Redis AOF I/O-Fehler → Authelia Down** | ✅ Fix live | Redis-AOF-Persistenz fehlschlug mit I/O-Error (nach k3s-12 Cascade). Fix: `CONFIG SET appendonly no/yes` + `BGREWRITEAOF` via crictl exec direkt auf Node. |
| **postgres-paperless I/O-Error nach k3s-12-Ausfall** | ✅ Fix live | Longhorn-Volume war healthy, aber Mount im Pod hatte stale I/O-State. Pod-Delete erzwang frischen Mount. |
| **Jellyfin CrashLoop — inotify limit** | ✅ Fix live + committed | `fs.inotify.max_user_instances=128` (Default) ausgeschöpft. Erhöht auf 512 auf allen Nodes via sysctl, persistiert in `/etc/sysctl.d/99-inotify.conf`. Ansible-common-Rolle aktualisiert. |
| **paperless-ai OOMKilled** | ✅ Fix committed | Memory-Limit 512Mi zu niedrig für AI-Workload. Erhöht auf 1536Mi, Request auf 512Mi, CPU-Limit auf 500m. Image auf `2.8.2` gepinnt. |
| **k3s-11 (Master) intermittent unreachable** | ✅ Root cause identified + mitigated | Root cause: load average 48–90 auf 4 CPUs durch 16+ App-Pods + Longhorn-Replicas + Controlplane gleichzeitig. Fix: k3s-11 mit `node-role.kubernetes.io/control-plane:NoSchedule` getaintet, alle App-Workloads auf k3s-12/13 evakuiert, Longhorn-Replicas nach k3s-12/13 migriert. Load sank von 90 → 1.04. Systemd-Override für k3s-agent Auto-Restart auf k3s-12/13 hinzugefügt. |
| **Garage stuck Pending nach k3s-11 Taint** | ✅ Fix committed | Garage hatte `requiredDuringSchedulingIgnoredDuringExecution` NodeAffinity auf `vm-srv-k3s-11`. Nach Taint konnte Scheduler Garage nirgendwo platzieren. Fix: nodeAffinity entfernt — Longhorn verwaltet PVC-Placement unabhängig. |
| **k3s-12/k3s-13 worker nur 3.8GB Allocatable** | 🟡 PR open → Atlantis pending | Proxmox balloon minimum (`floating`) war 4096 MB, Nodes zeigten nur ~3.8GB allocatable. K8s Scheduler lehnte Pods mit "Insufficient memory" ab (z.B. home-assistant Pending). Fix: `floating` für k3s-12 und k3s-13 auf 8192 MB erhöht. PR #37 offen — `atlantis apply` ausstehend. |
| **SABnzbd config PVC faulted nach k3s Chaos** | ✅ Fix live | Longhorn-Volume `pvc-6476c76f` (sabnzbd-config) als faulted markiert nach Node-Ausfällen. Einzige Replica war stopped. Fix: `spec.failedAt` und `spec.lastFailedAt` auf leer gesetzt via kubectl patch — Volume wechselte von `faulted detached` zu `attaching`. Daten erhalten. |
| **Authelia auf 2 Replicas + Health Probe** | ✅ Fix committed | Authelia lief mit 1 Replica (PDB existierte bereits). Auf 2 Replicas skaliert. Blackbox-Probe auf `/api/health` Endpoint ergänzt (zuvor nur `auth.woitzik.dev` mit Redirect → Traefik-Level). |

---

## Notes

- Velero backups target Garage S3 (`velero` bucket on `s3.woitzik.dev`)
- Atlantis handles all Terraform changes — PRs only, never `terraform apply` locally
- MikroTik firewall: all rules are Terraform-managed — no manual RouterOS changes
- Authelia OIDC: Proxmox/PBS/Grafana/Headscale use `client_secret_basic`; ArgoCD uses `client_secret_post`
- Keel: requires `keel.sh/policy` annotation on Deployments to trigger auto-updates
- Renovate: requires GitHub PAT applied via `kubectl create secret` — token is NOT committed
