# pve_zfs_health

ZFS pool health on `pve-mgmt-01` as Prometheus metrics, plus the monthly scrub.

## What it sets up

- `zfs-pool-metrics.timer` (every 5 min) runs `/usr/local/sbin/zfs-pool-metrics.py`,
  which parses `zpool status -j` for every pool and writes `zfs_pools.prom` to the
  node_exporter textfile collector: `zfs_pool_online`, `zfs_pool_state`,
  `zfs_pool_data_errors`, `zfs_pool_vdev_errors{type=read|write|checksum}`,
  `zfs_pool_scrub_running`, `zfs_pool_scrub_end_timestamp_seconds`,
  `zfs_pool_scrub_errors`, `zfs_pool_metrics_last_run_timestamp_seconds`.
- `/etc/cron.d/zfs-scrub-all`: scrubs every ONLINE pool on the second Wednesday of
  the month at 09:00. Each pool gets `org.debian:periodic-scrub=disable` so the
  Debian `zfsutils-linux` cron (second Sunday 00:24) does not scrub it as well;
  that slot overlapped PBS GC (02:00), the nightly backup (03:00) and the Sunday
  verify (06:30) for the ~6h a scrub of the USB `archive` pool takes.

Alerts: `storage.zfs` group in `kubernetes/system/monitoring/storage-capacity-alerts.yml`.

## Deploy

```sh
cd ansible && ansible-playbook site.yml --limit pve_hosts --check  # dry run first
cd ansible && ansible-playbook site.yml --limit pve_hosts
```

## After a data error

`zpool status -v <pool>` lists the damaged files. Restore or delete them, run
`zpool clear <pool>`, then a scrub; the error list only empties once a scrub
completes after the file is gone.
