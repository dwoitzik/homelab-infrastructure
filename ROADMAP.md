# Homelab Roadmap

## Services — Geplante Deployments

### Kurzfristig (nächste Wochen)

| Service | Namespace | Beschreibung | Prio |
|---|---|---|---|
| **Renovate Bot** | `apps` | Automatische Dependency-Updates via PRs auf GitHub | Hoch |
| **Mealie** | `apps` | Rezept-Manager (klein, schnell deployed) | Mittel |
| **Nextcloud** | `apps` | File Sync, CalDAV/CardDAV, Kontakte + Kalender | Mittel |

### Mittelfristig (nach 4TB SSD)

| Service | Namespace | Beschreibung | Prio |
|---|---|---|---|
| **Immich** | `apps` | Foto-Backup + ML Gesichtserkennung (braucht Storage + RAM) | Hoch |
| **Jellyfin** | `apps` | Media Server für Filme/Serien (braucht Storage) | Hoch |
| **Navidrome** | `apps` | Musik Streaming (klein, braucht Storage) | Mittel |

### Langfristig

| Service | Namespace | Beschreibung | Prio |
|---|---|---|---|
| **Home Assistant** | `apps` | Smart Home Hub | Mittel |
| **Gitea / Forgejo** | `apps` | Privates Git für Azure Enterprise Module | Mittel |
| **Uptime Kuma Monitors** | — | Alle Services monitoren (WebSocket API Setup nötig) | Niedrig |

---

## Hardware — Geplante Erweiterungen

### Kurzfristig

- **4TB SSD** (M.2 NVMe oder SATA) am Proxmox Host
  - Aktuell: lokaler ZFS-Pool (`local-zfs`) auf Systemplatte
  - Ziel: extra Datastore für Immich-Fotos, Jellyfin-Medien, Garage S3
  - Einbau: einfach, Proxmox erkennt automatisch

### Langfristig

- **Silent SSD NAS** (z.B. Synology DS223j oder QNAP TS-233)
  - Für Schlafzimmer — lautlos, passiv gekühlt
  - SMB/NFS Share → Longhorn External Storage oder direkter Mount in k3s
  - Für: Mediathek, Foto-Archiv, Backup-Ziel für Proxmox PBS

---

## RAM-Plan (Proxmox Host — 64GB)

| VM / LXC | Aktuell | Geplant | Notiz |
|---|---|---|---|
| k3s-11 (master) | 8 GB | **12 GB** (balloon: 4-12) | etcd + control plane |
| k3s-12 (worker) | 8 GB | **16 GB** (balloon: 4-16) | App-Workloads |
| k3s-13 (worker) | 8 GB | **16 GB** (balloon: 4-16) | App-Workloads |
| AI LXC (Ollama) | 32 GB | 32 GB | LLM inference |
| Docker LXC | 4 GB | 4 GB | |
| PBS | 2 GB | 2 GB | |
| DMZ Proxy | 1 GB | 1 GB | |
| DMZ Games | 4 GB | 4 GB | |
| **Gesamt statisch** | **67 GB** | **87 GB** | Balloon erlaubt Overcommit |

RAM-Update via Terraform → Atlantis PR bereits erstellt (`vm.tf`).

---

## Monitoring-Ausbau (in Arbeit)

- [ ] Ansible-Playbook ausführen: `ansible-playbook ansible/site.yml`
      → deployt `node_exporter` auf RPi-01, RPi-02, Docker-LXC, AI-LXC
- [ ] Proxmox API Token für `prometheus-pve-exporter` erstellen
      → Proxmox UI → API Tokens → `prometheus@pve!prometheus` → Rolle `PVEAuditor`
      → `kubectl edit secret pve-exporter-config -n monitoring`

---

## Notizen

- Velero Backups → Garage S3 (`velero`-Bucket auf `s3.woitzik.dev`)
- Atlantis: Terraform-Changes nur via PR → `atlantis apply` Kommentar
- MikroTik Firewall: Alle Regeln via Terraform — keine manuellen RouterOS-Änderungen
- Authelia OIDC: ***REMOVED*** = `client_secret_basic`, ArgoCD = `client_secret_post`
