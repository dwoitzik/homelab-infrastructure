# k3s_auto_upgrade

Nightly k3s upgrade orchestrated from the Proxmox host, with automatic rollback
(ADR-082). Runs on `pve_hosts`.

- `/usr/local/sbin/k3s-auto-upgrade`: upgrades the cluster to the `k3s_version` pinned in
  `ansible/k3s-cluster/inventory.yml` on `main`, one node at a time, through the QEMU
  guest agent (`qm guest exec`). Snapshots all k3s VMs first; any failed check rolls all
  of them back.
- `k3s-auto-upgrade.timer`: daily at 06:00; the run exits early unless there was a
  successful PBS backup in the last six hours (odd days) and no Velero backup is running.
- Notifications go to the ntfy topic used by the other host checks, only for skips,
  rollbacks and failures. Successful upgrades and drills only write to the log.
- Log: `/var/log/k3s-auto-upgrade.log`.

## Manual use

```sh
k3s-auto-upgrade --check            # health checks only
k3s-auto-upgrade --dry-run --force  # show what a run would do now
k3s-auto-upgrade --drill            # snapshot, roll back, verify (about 5 min of cluster downtime)
k3s-auto-upgrade --force            # upgrade now, outside the backup-night gate
```

## Bumping k3s

Renovate opens the PR for the pin. Patch releases merge after a week; minor releases
need a manual merge, one minor per PR. The next eligible night does the rollout.
