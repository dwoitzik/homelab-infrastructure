# ADR-004: 3-2-1 Backup strategy with PBS and rclone

**Date:** 2026-04
**Status:** Accepted

## Context

A homelab running production-grade services (Vaultwarden, monitoring, DNS) requires a reliable backup strategy. The requirements were:

- Automated, unattended backups with no manual intervention
- Protection against local hardware failure (disk, host, fire)
- Offsite copy with encryption to protect sensitive data
- Efficient use of bandwidth — only changed data uploaded
- Ability to fully reconstruct the homelab from scratch

## Decision

Implement the industry-standard **3-2-1 rule**:
- **3** copies of data
- **2** different storage media
- **1** offsite copy

### Stage 1 — Local backup (Proxmox Backup Server)

Proxmox Backup Server runs as an LXC (`ct-mgmt-pbs-01`, VLAN 10) on a dedicated 2TB HDD mounted at `/mnt/pbs-storage`. All LXCs are backed up daily at 03:00 via the Proxmox backup scheduler with a 7 daily / 4 weekly retention policy. PBS uses block-level deduplication — only changed chunks are stored, minimising disk usage.

### Stage 2 — Offsite cloud backup (Google Drive via rclone)

A cron job runs daily at 04:00 syncing the PBS datastore to Google Drive (`gdrive:Backup-Homelab/PBS`) via rclone. PBS encrypts backup data at rest before it leaves the host — the Google Drive copy is encrypted client-side and cannot be read without the PBS encryption key. Only changed chunks are uploaded due to PBS deduplication, minimising bandwidth.

A Healthchecks.io ping confirms successful completion — if the sync fails or doesn't run, an alert fires.

### Stage 3 — Disaster recovery

In the event of total local hardware failure:
1. Reinstall Proxmox VE on new hardware
2. Deploy a fresh PBS LXC via Ansible
3. Link Google Drive via rclone (`rclone config`)
4. Mount the remote directory as a PBS datastore and provide the encryption key
5. Restore all LXCs directly from deduplicated cloud chunks

## Reasons

**PBS over Bacula/Amanda:** PBS is native to Proxmox, supports LXC/VM snapshots natively, and has a clean web UI for restore operations. No external backup agent needed.

**Google Drive over S3/Backblaze:** Existing account, generous free storage, no per-request charges. rclone abstracts the provider — switching to a different cloud requires only a rclone remote change.

**rclone sync over rsync:** rclone handles OAuth token refresh automatically and supports server-side checksums for Google Drive. The `--transfers 8 --checkers 16` flags parallelise operations for faster sync.

**Healthchecks.io:** Dead man's switch pattern — the cron job must actively report success. Silence = failure = alert. More reliable than checking cron logs manually.

## Trade-offs

- Google Drive OAuth token must be rotated manually when it expires (mitigated by storing in Ansible Vault and redeploying)
- No versioning beyond what PBS retention policy provides — PBS prune handles this
- Single Proxmox node — no live migration failover, only restore-from-backup DR

## Consequences

The PBS role is managed by Ansible (`roles/pbs`). The rclone token is stored in Ansible Vault and deployed as `/root/.config/rclone/rclone.conf` on `ct-mgmt-pbs-01`. The sync script is templated and managed — no manual edits on the container.
