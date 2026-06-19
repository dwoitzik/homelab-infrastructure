# Backup Strategy: 3-2-1 Rule

The homelab follows the 3-2-1 rule: 3 copies of data, on 2 different media, with 1 copy offsite. All backups are fully automated.

## Stage 1 — Kubernetes Workloads (Velero)

**What:** All persistent volumes and namespace resources in the k3s cluster.

- **Tool:** Velero (with `defaultVolumesToFsBackup: true` — backs up actual PVC data via
  Kopia, not just k8s manifests. `nfs-client` storage class has no CSI snapshotter, so
  this filesystem-level backup is the *only* way PVC data gets captured.)
- **Backend:** Garage S3 (`s3.woitzik.dev`, bucket: `velero`)
- **Schedule:** Daily at 03:00, TTL 30 days
- **Scope:** All namespaces (`apps`, `database`, `monitoring`)
- **Recovery:** `velero restore create --from-backup <name>`

> **Incident note (2026-06-19):** `defaultVolumesToFsBackup` was missing from the schedule
> for an unknown period. Backups completed "successfully" the entire time but only
> contained Kubernetes object manifests — none of the actual data in Postgres, Vaultwarden,
> Paperless, or Nextcloud volumes. Always verify a backup with
> `velero backup describe <name> --details | grep -A5 "Pod Volume Backups"` after touching
> the schedule — a `<none included>` here means the backup is decorative.

## Stage 1b — Offsite (Cloudflare R2)

**What:** Critical namespaces only (`apps`, `vault`, `database`, `argocd`) — excludes
`media` (1TB), Prometheus/Loki/Garage data volumes via `velero.io/exclude-from-backup=true` label.

- **Tool:** Velero, second `BackupStorageLocation` (`r2-offsite`)
- **Schedule:** Daily at 04:00, TTL 7 days
- **Status:** Configured (`kubernetes/system/velero/offsite-schedule.yml`,
  `r2-backuplocation.yml`) but **not yet active** — waiting on David to provide a
  Cloudflare R2 Account ID + API token. See `docs/secrets-inventory.md`.

## Stage 2 — VM/LXC Snapshots (PBS)

**What:** All Proxmox VMs and LXC containers (full disk images).

- **Tool:** Proxmox Backup Server (`ct-mgmt-pbs-01`, VLAN 10)
- **Storage:** 2 TB HDD (`/dev/sdb1`) at `/mnt/pbs-storage`
- **Retention:** 7 daily / 4 weekly snapshots
- **Schedule:** Daily at 03:00 (block-level deduplication, only changed chunks stored)
- **Recovery:** Restore directly from PBS in the Proxmox web UI

## Stage 3 — Offsite Cloud (rclone → Google Drive)

**What:** PBS datastore synced to Google Drive for offsite copy.

- **Tool:** rclone
- **Schedule:** Daily at 04:00 (`rclone sync`)
- **Destination:** `gdrive:Backup-Homelab/PBS`
- **Encryption:** Client-side encrypted by PBS before upload; unreadable without PBS encryption key

## Disaster Recovery

**Full cluster loss (VMs gone):**
1. Reinstall Proxmox VE
2. Restore VMs/LXCs from PBS (local) or via rclone from Google Drive
3. k3s will self-restore once VMs are up
4. Restore Velero backups: `velero restore create --from-backup <name>`

**Kubernetes data loss only (cluster intact):**
1. `velero restore create --from-backup <name> --include-namespaces apps`
