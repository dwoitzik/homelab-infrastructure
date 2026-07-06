# Backup Strategy: 3-2-1 Rule

The homelab follows the 3-2-1 rule: 3 copies of data, on 2 different media, with 1 copy offsite. All *local* backups are fully automated. **Neither offsite leg is currently active**: Stage 1b (Cloudflare R2) is scaffolded but deliberately not turned on (WRK-008), and Stage 3 (Google Drive) was deliberately disabled by the account owner due to insufficient Drive storage (REL-051). Both are documented below with their current real status, not the originally-intended one.

## Stage 1 — Kubernetes Workloads (Velero)

**What:** All persistent volumes and namespace resources in the k3s cluster.

- **Tool:** Velero (with `defaultVolumesToFsBackup: true` — backs up actual PVC data via
  Kopia, not just k8s manifests. `nfs-client` storage class has no CSI snapshotter, so
  this filesystem-level backup is the *only* way PVC data gets captured.)
- **Backend:** Garage S3 (`s3.woitzik.dev`, bucket: `velero`)
- **Schedule:** Daily at 03:00, TTL 7 days (re-verified against `kubernetes/system/velero/schedule.yml`'s `ttl: 168h0m0s` 2026-07-06 -- this doc previously said 30 days)
- **Scope:** All namespaces except `kube-system`/`kube-public`/`kube-node-lease` (`includedNamespaces: ["*"]` with those 3 excluded) -- not just `apps`/`database`/`monitoring` as previously stated here
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

## Stage 3 — Offsite Cloud (rclone → Google Drive) · **deliberately disabled, see REL-051**

**What:** PBS datastore synced to Google Drive for offsite copy.

- **Status as of 2026-07-06: intentionally off.** The account owner disabled the cron
  job themselves (around 2026-06-14) because the destination Google Drive account
  doesn't have enough free space for the PBS datastore. Config/script stay deployed
  (harmless), the schedule itself is deliberately `state: absent` in
  `ansible/roles/pbs/tasks/main.yml`. This is currently the **only** offsite copy in
  this doc's 3-2-1 strategy that's active — see the note at the top of this file.
- **Tool:** rclone
- **Schedule (when re-enabled):** Daily at 04:00 (`rclone sync`)
- **Destination:** `gdrive:Backup-Homelab/PBS`
- **Encryption:** Client-side encrypted by PBS before upload; unreadable without PBS encryption key
- **Known issue, separate from the quota problem — re-enabling this needs solving it
  too:** even when the cron job ran (2026-05-04 through 2026-06-14, before the quota
  ran out), it nearly always failed anyway. Root cause: Google Drive's API throttles
  hard on PBS's chunked storage format (tens of thousands of small files) — a manual
  test sync showed ~1.6 KiB/s and a ~12-week ETA for the initial full sync. This isn't a config
  bug, it's a fundamental mismatch between Drive's API and this data shape. Needs a
  decision (long unattended initial sync, pre-bundling chunks, or a different offsite
  target) before this stage can be considered actually working — see REL-051.

## Disaster Recovery

Full rebuild and per-service restore procedures live in
[`DISASTER-RECOVERY.md`](../DISASTER-RECOVERY.md) at the repo root — covering Proxmox
rebuild, k3s bootstrap, ArgoCD bootstrap, Vault init/unseal, ExternalSecrets sync, and
Velero restore in detail. This page only covers backup *mechanics* (what's backed up,
where, how often); the other doc covers *recovery* (what to run, in what order).

Quick reference for the two most common cases:

- **Full cluster loss (VMs gone):** Proxmox rebuild → restore VMs/LXCs from PBS → k3s
  bootstrap (not automatic — see `DISASTER-RECOVERY.md` Tier 2) → ArgoCD bootstrap → Vault
  init/unseal → Velero restore.
- **Kubernetes data loss only (cluster intact):**
  `velero restore create --from-backup <name> --include-namespaces apps`
