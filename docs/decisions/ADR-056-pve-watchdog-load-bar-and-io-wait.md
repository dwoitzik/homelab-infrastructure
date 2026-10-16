# ADR-056: The pve watchdog's load bar tracks I/O-wait, not just CPU

- **Status**: Accepted and applied, 2026-10-16
- **Relates to**: ADR-034 (single DRAM-less NVMe, ZFS/vzdump tuning), ADR-053 (the same
  watchdog's backup-window bar), PR #891 (which had muted the watchdog entirely),
  `ansible/roles/pve_power/templates/pve-watchdog.sh.j2`

## Context

`pve-mgmt-01` runs `pve-watchdog.sh` from cron every 5 minutes and alerts via ntfy on
pool usage, CPU temperature, and host load. The load half had become a false-positive
magnet: alerts at load 32-34 arrived at 23:55, 07:20, and 08:25 — no backup running, no
bulk apply, just the box doing ordinary work. PR #891 responded by deleting the ntfy
send line outright ("disable ntfy alerts to stop spam"), which also silently removed the
pool-≥92% and CPU-≥90 °C alerts the watchdog exists for.

The host's real bottleneck is I/O, not CPU. A single DRAM-less NVMe (already the
subject of ADR-034's tuning) saturates under the k3s VMs' ordinary disk traffic:
observed `iostat` `%util` 92%, `nvme0n1` ~1000 read IOPS at ~30 MB/s, `/proc/pressure/io`
`full avg10` around 23%, and swap 7.4 GiB of 8 GiB used. Under that pressure, processes
sit in D-state (uninterruptible I/O) and `loadavg` counts them — so a load of 30-40 here
is mostly tasks waiting on the disk, not a CPU runaway. The watchdog's bar never
accounted for that.

## Decision

- **Load bar 40 → 50** outside a backup. The box genuinely runs 30-40 on I/O-wait
  alone, so 40 sat inside normal noise; 50 clears it while staying below the ~56 that a
  PBS backup reaches.
- **Backup-window bar 80 → 90** (unchanged mechanism: `pgrep -x vzdump`, not a clock).
- **Pool-≥92% and CPU-≥90 °C alerts restored.** These are real signals; #891's blanket
  mute traded them away to stop a load-noise problem they had nothing to do with.
- **The escalating backoff stays** (initial 30 min, doubling to `MAX_BACKOFF_MIN` 480),
  so a genuinely sustained condition still tapers instead of paging every 5 minutes.
- **Fix the "during backup" suffix bug.** `VZDUMP_RUNNING` is set to `0` or `1`, both
  non-empty, so `${VZDUMP_RUNNING:+ during backup}` expanded on *every* alert — which is
  why the 23:55/07:20 alerts all claimed "during backup" with no backup running. The
  suffix is now built only when `vzdump` is actually present.

## Consequences

- A real over-temperature or near-full thin pool notifies again (regression from #891
  closed).
- Load alerts should now mean something: 50 is above the I/O-wait floor this host
  routinely sits at.
- The underlying I/O saturation is **not** fixed by this ADR — the bar was moved to stop
  false alerts, not to excuse the load. Reducing NVMe pressure (or the swap usage) is
  separate follow-up work.
- The same ntfy topic also carries the claude-agent LXC's own nudge watchdogs, so the
  topic is noisier than the host's alerts alone; splitting that topic was considered and
  deliberately declined.
