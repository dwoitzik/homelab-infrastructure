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

### In Progress

| Service | Status | Notes |
|---|---|---|
| **Claude Code Web Terminal** | 🔄 PR #38 offen | CT `ct-srv-claude-01` (VMID 221, 10.0.20.120). Ansible-Rolle `claude_terminal` bereit. `vault_claude_ttyd_password` in Vault eintragen, dann `ansible-playbook` laufen lassen. Nach Provisioning: `claude login` als `claude`-User einmalig ausführen (OAuth, kein API-Key nötig). |
| **NFS Storage Migration** | ✅ Abgeschlossen | Alle PVCs auf `storageClassName: nfs-client` migriert. Longhorn entfernt. NFS-Server: `ct-srv-nfs-01` (10.0.20.100, VMID 220). |

### Pending (other)

| Service | Notes |
|---|---|
| **Uptime Kuma Monitors** | WebSocket API setup required via web UI at status.woitzik.dev — Script `ansible/add_kuma_monitors.py` liegt bereit, benötigt API-Token aus Kuma UI. |
| **NFS Media Share** | ~~NFS Server on Proxmox Host~~ → `ct-srv-nfs-01` übernimmt jetzt auch Media-Shares. Export `/nfs-data/jellyfin` bereits konfiguriert. Jellyfin-PVC auf NFS migrieren sobald Storage-Migration abgeschlossen. |
| **Ollama GPU passthrough** | AMD Radeon iGPU → AI LXC via IOMMU — enables ROCm acceleration for paperless-ai. Proxmox: IOMMU in Grub aktivieren (`amd_iommu=on iommu=pt`), LXC Device-Mapping für `/dev/dri`. Ollama benötigt ROCm-fähiges Image (`ollama/ollama:rocm`). |
| **Paperless → Nextcloud consume** | Mount Nextcloud shared folder als Paperless consume PVC: Nextcloud External Storage App → lokales Filesystem, dann NFS-PV in k3s für Paperless `consume` mounten. Alternativ: Paperless WebDAV-Consume direkt auf Nextcloud-WebDAV. |
| **Claude Code Web Terminal** | Claude Code CLI + `ttyd` als Web-Terminal im Homelab — sodass du ohne lokalen PC weiterarbeiten kannst. Deployment: neuer CT `ct-srv-claude-01` (VMID 222) oder k3s Deployment mit `ttyd` + Claude Code CLI. Zugriff über `claude.woitzik.dev` (Authelia-geschützt). Benötigt Anthropic API-Key in Vault. ttyd: `ttyd --port 7681 --credential user:pass claude` oder direkt als k8s Deployment mit NFS PVC für Workspace-Persistenz. |
| **Remote Dev Environment (code-server)** | VS Code Server auf k3s — `coder/code-server:latest` als k8s Deployment, 2Gi PVC für Workspace, Authelia-geschütztes IngressRoute. Benötigt: gepinntes Image, ResourceLimits (Kyverno), PVC mit ReadWriteOnce. |

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
| ~~**Authelia OIDC `hmac_secret` in Vault**~~ ✅ | `hmac_secret` aus ConfigMap entfernt, in Vault KV v2 unter `secret/authelia` abgelegt. ExternalSecret mit `creationPolicy: Merge` synct den Key in `authelia-secrets`. ConfigMap referenziert `/config/secrets/hmac-secret`. |
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
| **Authelia `latest` Image-Tag** | ✅ Fix committed | `ghcr.io/authelia/authelia:latest` verletzt Kyverno-Policy `disallow-latest-tag`. Gepinnt auf `4.39.20`. |
| **k3s-12 NotReady (kubelet Lease verloren)** | ✅ Fix live | k3s-agent auf k3s-12 hatte Verbindungsabbruch zur API-Server. `systemctl restart k3s-agent` auf k3s-12 behoben. |
| **Redis AOF I/O-Fehler → Authelia Down** | ✅ Fix live | Redis-AOF-Persistenz fehlschlug mit I/O-Error nach k3s-12 Cascade. Fix: `CONFIG SET appendonly no/yes` + `BGREWRITEAOF`. |
| **Jellyfin CrashLoop — inotify limit** | ✅ Fix committed | `fs.inotify.max_user_instances=128` erschöpft. Erhöht auf 512 auf allen Nodes, persistiert via Ansible-common-Rolle. |
| **paperless-ai OOMKilled** | ✅ Fix committed | Memory-Limit 512Mi zu niedrig. Erhöht auf 1536Mi, CPU-Limit auf 500m. Image auf `2.8.2` gepinnt. |
| **k3s-11 (Master) intermittent unreachable** | ✅ Fixed + mitigated | Load average 48–90 durch App-Pods + Longhorn-Replicas + Controlplane. Fix: k3s-11 getaintet (`NoSchedule`), App-Workloads auf k3s-12/13 evakuiert. Load sank von 90 → 1.04. |
| **Garage SQLite Corruption** | ✅ Recovered | Unclean shutdown durch OOM. `db.sqlite` Pages 169–184 korrupt. Recovery: `.recover`-Befehl. terraform-state Bucket + Atlantis-Key neu via Python/msgpack in SQLite eingetragen (Garage-Format: `b'G2key'`/`b'G2bkt'` + msgpack-dict, bucket_id als bytes(32)). Atlantis-Workflow von broken filesystem-mirror auf standard `init`/`plan` umgestellt. |
| **Paperless OOMKilled (16x in 5h)** | ✅ Fix live | Tesseract+Tika OCR-Burst überschritt 1Gi Limit + schedulete auf Master (k3s-11) wegen Toleration. Fix: Memory-Limit 1Gi→3Gi, CPU 500m→2000m, TASK_WORKERS=2, THREADS=2, Control-Plane Toleration entfernt. Läuft jetzt auf vm-srv-k3s-12. |
| **AdGuard 1.58M DNS-Queries/Tag** | ✅ Fix live | CoreDNS TTL 30s verursachte 1.2M Queries. Fix: CoreDNS cache 30→300s (kubectl patch), AdGuard cache_optimistic=true + 64MB Cache (Ansible). |
| **Homepage RAM negative (-250MiB, -1GiB)** | ✅ Fix in PR #39 | Proxmox balloon minimum 4096MB → balloon schrumpfte auf 3.8GB unter Host-Pressure. Fix: floating=8192 für k3s-12/13 in vm.tf. |
| **Authelia Schema-Mismatch (DB v24 vs Image v15)** | ✅ Fix committed | DB hatte Schema v24 (geschrieben von v4.39.20), Deployment nutzte v4.38.18 (max v15). Fix: Image auf `4.39.20` angehoben. |
| **k3s-12/k3s-13 worker nur 3.8GB Allocatable** | ✅ Fix live | Proxmox balloon minimum war 4096 MB → kubelet registrierte 3.8GB Capacity beim Start. Fix: Balloon via Proxmox API auf 16GB gesetzt + `systemctl restart k3s-agent` auf k3s-12/13. Nodes zeigen jetzt `Capacity: memory: 16383272Ki` (16 GiB). |
| **Longhorn cross-node attach Dauerschleife** | 🔄 In Arbeit | RWO-Volumes wurden bei OOM auf Node A attached, Pods aber auf Node B neu gestartet → `Multi-Attach error`. Root cause: Longhorn taugt nicht für volatile Node-Umgebungen. **Fix: Migration aller PVCs von Longhorn → NFS (ct-srv-nfs-01)**. In Progress — siehe Storage Migration. |
| **SABnzbd config PVC faulted** | 🟡 Data loss | Longhorn-Volume `pvc-6476c76f` faulted+detached nach multiplen Node-Ausfällen. Nur noch fresh-start möglich. Neue NFS-PVC wird erstellt. |
| **Authelia auf 2 Replicas + Health Probe** | ✅ Fix committed | Auf 2 Replicas skaliert. Blackbox-Probe auf `/api/health` ergänzt. |
| **NFS CT falsches Namensschema** | ✅ Fix committed | CT hieß `vm-srv-nfs-01` — muss `ct-srv-nfs-01` sein (LXC = `ct` Prefix). Terraform-Ressource + Import ergänzt, Tags gesetzt, Hostname auf CT korrigiert. |

---

## Notes

- Velero backups target Garage S3 (`velero` bucket on `s3.woitzik.dev`)
- Atlantis handles all Terraform changes — PRs only, never `terraform apply` locally
- MikroTik firewall: all rules are Terraform-managed — no manual RouterOS changes
- Authelia OIDC: ***REMOVED*** use `client_secret_basic`; ArgoCD uses `client_secret_post`
- Keel: requires `keel.sh/policy` annotation on Deployments to trigger auto-updates
- Renovate: requires GitHub PAT applied via `kubectl create secret` — token is NOT committed
