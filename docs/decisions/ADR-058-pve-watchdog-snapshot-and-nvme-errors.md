# ADR-058: The pve watchdog also flags stale snapshots and NVMe resets

- **Status**: Accepted and applied, 2026-10-16
- **Relates to**: ADR-034 (single DRAM-less NVMe), ADR-053/ADR-056 (this watchdog),
  PR #908 (the vault-unseal I/O incident these checks came out of),
  PR #909, `ansible/roles/pve_power/templates/pve-watchdog.sh.j2`

## Context

Cleaning up after the vault-unseal incident (the I/O loop fixed in PR #908) required
two things to be found by hand that the watchdog should have flagged on its own:

1. **Leftover COW snapshots.** Manual Proxmox snapshots taken while investigating
   (`snap_vm-211-disk-0_vault-hang-pre-snapshot`, and others) sat on the thin pool for
   days. A thin snapshot is a silent write amplifier -- every changed block of its
   origin is copied on write -- so an investigation snapshot left behind keeps costing
   I/O indefinitely. Nothing watched for that; the pool-usage bar only fires at 92%.
2. **Kernel NVMe resets.** During the stall the kernel logged the NVMe "timeout,
   aborting" / controller-reset lines that are the real early warning of a drive
   dropping commands under load. The watchdog checked pool %, CPU temp, and load -- not
   the disk's own error log.

The watchdog (every 5 min, ntfy, escalating backoff from ADR-056) already exists to catch
this host's failure modes. Both signals belong there rather than in a new job.

## Decision

Extend `pve-watchdog.sh` with two checks, both appended to the same `ALERT` string so
they inherit the existing ntfy topic, maintenance-mode suppression, and backoff:

- **Stale snapshot**: any LV named `snap_*` whose `lv_time` is at least
  `pve_power_watchdog_snapshot_max_age_days` (default **7**) old.
- **NVMe errors**: any `nvme*` kernel line matching timeout / aborting / controller-down
  / reset / I/O-error within the last
  `pve_power_watchdog_nvme_error_window_min` (default **30**).

NVMe **wear** (`percentage_used`) is deliberately **not** duplicated here: `smart-metrics`
already exports it to Prometheus every 15 min and the monthly `ssd_wear_check` role warns
at 80%. One source per signal.

## Consequences

- A forgotten snapshot or a resetting SSD now notifies within one 5-minute cycle instead
  of waiting to be noticed during the next incident.
- A deliberately-retained snapshot older than 7 days will alert — that is the point;
  silence it by removing the snapshot or raising the variable, not by ignoring it.
- Two extra `lvs` / `journalctl` invocations per 5-minute run: negligible.
- This does not prevent the conditions, only surfaces them. Root-cause fixes remain the
  PR #908 class of change.
