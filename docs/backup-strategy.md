# Backup Strategy: 3-2-1 Rule

We follow the industry-standard 3-2-1 rule: 3 copies of data, on 2 different media, with 1 copy stored offsite. Backups are fully automated to ensure consistency.

## 1. Local Backup (Stage 1)
- **Target:** Proxmox Backup Server (`ct-mgmt-pbs-01` on VLAN 10).
- **Storage:** 2 TB HDD (`/dev/sdb1`) mounted at `/mnt/pbs-storage`.
- **Retention Policy:** 7 daily / 4 weekly snapshots (Prune & Garbage Collection active).
- **Schedule:** Daily at 03:00 AM.
- **Hardware Efficiency:** Spin-down active (10 min) to reduce noise and mechanical wear.

## 2. Offsite Cloud Backup (Stage 2)
- **Service:** Google Drive (via `rclone`).
- **Security Logic:** Client-side encrypted by PBS before upload. PBS block-level deduplication ensures only changed chunks are uploaded, minimizing bandwidth.
- **Schedule:** `rclone sync` runs daily at 04:00 AM via Cron.
- **Path:** `gdrive:Backup-Homelab/PBS`

## 3. Disaster Recovery Protocol
In the event of total local hardware failure:
1. Reinstall Proxmox VE.
2. Deploy a fresh PBS Container.
3. Link Google Drive via `rclone`.
4. Mount the remote directory as a Datastore in PBS and provide the encryption key.
5. Reconstruct and restore VMs/LXCs directly from the deduplicated cloud chunks.
