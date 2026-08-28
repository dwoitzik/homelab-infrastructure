# ADR-034: Proxmox Host Power and Reliability Tuning

**Date:** 2026-08-28 (consolidating tuning applied incrementally between
2026-08-17 and 2026-08-22)
**Status:** Accepted, implemented

## Context

`pve-mgmt-01` is a single Ryzen 5825U host on one DRAM-less consumer NVMe
carrying every VM, LXC, and container workload in this homelab (see
`CLAUDE.local.md`'s hardware inventory — there is no second host, no
second disk to isolate noisy jobs onto). That constraint drove a series of
related host-level tuning decisions, applied incrementally as each gap was
found rather than all at once. This ADR is the single place they're
explained together; `ansible/roles/pve_power/` is where they're
implemented.

Related: `ADR-023` (the shared-disk bulk-I/O guard) addresses the same
"one disk, many tenants" constraint at the *scheduling* layer — this ADR
covers the host's own power/kernel-parameter tuning, a related but
distinct concern.

## Decisions

**CPU governor: `powersave` + AMD P-State `active` + EPP
`balance_power`.** AMD's hardware P-state driver (`amd_pstate=active`)
replaces the generic `cpufreq` subsystem and only offers `performance`/
`powersave` as governors — `schedutil` isn't available under active mode.
EPP (Energy Performance Preference) does the actual fine-grained
power/performance balancing on top of that, so `powersave` is the correct
governor choice here, not a compromise.

**ZFS module tuning** (`arc_max`, `prefetch_disable`, `dirty_data_max`,
`txg_timeout`, `zfs_vdev_async_write_max_active`): brings previously
manually-applied kernel module parameters under IaC. The one substantive
addition beyond capturing prior manual state:
`zfs_vdev_async_write_max_active` caps bulk async writes from any
guest well below the ZFS I/O scheduler's synchronous-write ceiling, so a
latency-sensitive synchronous writer (e.g. a database's WAL fsync) isn't
competing on equal footing with a bulk background write for the single
shared SSD's queue.

**`vzdump` global throttle** (`bwlimit`/`ionice`): backup I/O yields to
everything else on the shared NVMe by running at the lowest best-effort
I/O priority class and a capped bandwidth, rather than competing at full
speed against live workloads during a backup window.

**LVM thin-pool autoextend threshold raised from 80% to 92%.** This
host's single physical volume has zero free space at the volume-group
level, so LVM's autoextend mechanism can structurally never succeed —
the default 80% threshold only ever blocked new thin-LVs (i.e. every
`vzdump` backup) once utilization crossed it, for no actual protection in
return, since there was never any free space to extend into. Raised
rather than disabled outright, to keep a real margin before the
unrecoverable "pool actually full" failure mode, which risks I/O
errors/corruption across every guest on the pool — categorically worse
than a single failed backup.

**PBS backup health-check hook**, registered as `vzdump`'s job-end
script: verifies each backup's real datastore manifest size and age per
VMID, not just `vzdump`'s own exit status. A backup job reporting success
while writing a near-empty archive is a real, previously-observed failure
mode this specifically catches — `vzdump`'s own success/failure signal
doesn't distinguish "wrote a complete backup" from "wrote a stub and
exited 0."

**Host watchdog with escalating backoff** (15/30/60/120/240 minutes,
resetting when the underlying condition actually clears), replacing a
flat rate-limit that re-alerted every check cycle for a single ongoing
condition. A genuinely new problem starting at any point still alerts
promptly; an already-known, still-ongoing one doesn't spam.

**World-readable RAPL energy counters** (`/sys/class/powercap/intel-rapl:0/energy_uj`):
the kernel's power-monitoring interface defaults to root-only, which
silently breaks any unprivileged metrics exporter trying to read real
power-draw data. The energy counter value itself isn't sensitive —
making it world-readable via udev rule (durable across reboots/device
re-enumeration) is the standard fix for this class of gap, not a
security trade-off.

**`vm.swappiness` reduced from the OS default to 5** (not disabled
entirely). This host showed sustained active swap I/O under real memory
pressure — every swapped page is a write to the same NVMe every other
decision in this ADR is trying to reduce wear on. Reduced rather than
minimized to near-zero: this host has genuine memory-pressure headroom
problems under load (see `docs/HARDWARE.md`'s wear projection), and an
overly aggressive reduction trades "less swap I/O" for "more OOM-kill
risk" — a worse trade when memory pressure is already a known, real
constraint here.

## Trade-offs (accepted)

- None of this tuning was applied atomically as a single design — it
  accreted incident by incident. That's reflected honestly here rather
  than presented as a single upfront plan; the common thread (this host's
  hardware constraints) is real, the timing wasn't planned.
- The LVM autoextend threshold and the ZFS/vzdump tuning are all
  mitigations for a hardware constraint (one disk, no headroom) rather
  than a fix for it — the actual fix would be a second disk or a second
  host, neither of which exists. Documented as the accepted reality, not
  a gap being silently worked around.

## Consequences

- `ansible/roles/pve_power/` implements every decision above.
- `ansible/roles/node_exporter_native/` (a separate role, runs after this
  one in `site.yml`'s `pve_hosts` play) manages `node_exporter`'s own
  service definition and `--collector.textfile.directory` flag — not
  duplicated in this role, since a `lineinfile` edit against a file
  another role fully templates would just get overwritten on that role's
  next run.
