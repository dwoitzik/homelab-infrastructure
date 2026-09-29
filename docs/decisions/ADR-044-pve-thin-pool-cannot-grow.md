# ADR-044: pve/data Cannot Grow — fstrim Is the Only Reclamation Mechanism

**Date:** 2026-09-29
**Status:** Accepted. The reclamation fix is applied (PR #798, verified live).
The capacity ceiling itself is **not** resolved and remains open — see Open
Decisions.

## Context

Two alerts fired within an hour on 2026-09-29:

```text
[FIRING:1] KubeAPIServerDown            08:05
[FIRING:1] ProxmoxStorageCapacityHigh  09:11  storage/pve-mgmt-01/local-lvm 85.03%
```

David reported the load as "gottlos hoch" and asked for it to be handled
sustainably. The three symptoms looked like unrelated problems. They are
one.

### The capacity alert

`local-lvm` reached 85% and could not be relieved by any normal means,
because the volume group has no free space to grow into:

```text
PV             VG  PSize  PFree
/dev/nvme0n1p3 pve 475.94     0
```

`/dev/nvme0n1p3` is entirely consumed by the 460.8 GiB thin pool, 8 GiB
swap and 3.6 GiB of thin metadata. `thin_pool_autoextend_threshold` is
already configured to 92 by the `pve_power` role, and that setting is
**inert** — there are no free extents for autoextend to claim. No amount
of pool-headroom tuning changes this; it is a property of the partition
layout.

### The reclamation mechanism, and why it had never run

The role already deploys `fstrim-all.sh` (host root + every LXC + every
VM), and its own header names this exact failure mode:

> Thin-pool blocks stay allocated until TRIMmed -- this is what silently
> pushes pve/data's data_percent toward REL-019's ENOSPC territory.

It had never reclaimed a single block. `/var/log/fstrim-all.log` recorded
every scheduled run:

```text
/usr/local/bin/fstrim-all.sh: line 6: fstrim: command not found
/usr/local/bin/fstrim-all.sh: line 8: pct: command not found
/usr/local/bin/fstrim-all.sh: line 12: qm: command not found
```

`cron` runs with a minimal `PATH` that omits `/usr/sbin`, where `fstrim`,
`pct` and `qm` live on PVE. The failure was silent by construction: the
script redirects its own output to the log file, the crontab entry looked
correct, and nothing read that log. A protective mechanism existed,
was scheduled, and provided no protection.

### A correction worth recording

The first hypothesis was that `fstrim` was running but the guests' free
space was simply never-allocated space with no holes to reclaim. That was
wrong, and checkably so: `pve/root` reported `93.88%` in the pool while
`df` reported `49%` on the same filesystem — 20.8 GiB of allocated blocks
the filesystem no longer referenced. Discard *is* passed through to the
pool; the weekly timer had simply not run since that data was freed, and
with a full run taking over ten minutes under load, a week is a long time
to sit at the edge.

## Decision

1. **Fix the PATH and fail loudly.** The script exports an explicit `PATH`
   and exits non-zero if any of the three binaries is still unresolvable,
   so a future regression surfaces as a failed job rather than a log
   nobody reads.
2. **Run it daily, not weekly.** With `PFree=0`, TRIM is the *only*
   mechanism that returns space to this pool. A weekly cadence is not a
   defensible interval for a storage device with no growth headroom.

PR #798, applied and verified live.

## Verification

Same script, PATH corrected, run against the live host:

| | before | after |
|---|---|---|
| `pve/data` | 85.09% (68.7 GB free) | **61.97% (175 GB free)** |
| `pve/root` | 93.88% | **48.46%** |
| host `iowait` | 63% | **9%** |
| host load (1 min) | 5.03 | 2.84 |

`fstrim -v /` reported `20.8 GiB trimmed` on the host root alone. Deployed
via the `pve_power` role; cron now reads `30 4 * * *`.

### The connection between all three symptoms

`vm-212` writeIOPS fell from 1769 to 3.9 and `vm-213` from 2627 to 159
over the same window, and kine slow-request warnings on `k3s-11` went
from 219 per 60 s to 0 per 15 min. Only `k3s-11` runs a k3s server
(`k3s-12`/`13` are agents with no `k3s-server` process and no
`server/db`), so the SQLite fsync storm had a single origin.

The causal chain, in order:

1. `fstrim-all.sh` never ran (cron `PATH`)
2. thin-pool blocks were never released; `pve/data` filled to 85%
3. pool pressure drove host `iowait` to 63%
4. synchronous SQLite writes on `k3s-11` queued behind that latency
5. kine fell behind, and the API server stopped answering on time

`KubeAPIServerDown` was therefore a *storage* symptom wearing a
control-plane label, and REL-012's "kine/SQLite latency under disk I/O
contention" was correct about the mechanism while pointing at the wrong
layer. The alert's own suggested next step — checking
`journalctl -u k3s` for `apply request took too long` — finds the
consequence, not the cause.

## Consequences

- `ProxmoxStorageCapacityHigh` is resolved by mechanism, not by raising a
  threshold. The pool is at 62% and now reclaims daily.
- `KubeAPIServerDown` has a known root cause and is expected to stop
  recurring while daily TRIM holds.
- Two alerting gaps were exposed in the process and are **not** fixed
  here: `pve_pbs_backup_healthy` is referenced by the landing dashboard
  but defined by no exporter, and the PBS healthcheck hook is registered
  twice in `/etc/vzdump.conf`.
- The capacity ceiling is unchanged. 175 GB of headroom is better than 68,
  but the pool still cannot grow, and `thin_pool_autoextend_threshold`
  remains decorative.

## Open Decisions

The structural problem is unaddressed by this ADR, deliberately. Two
directions, both requiring David's decision:

1. **Move guests off the NVMe.** `sdb` (SanDisk 3.2Gen1, 452 GB) is only
   20% used with 348 GB free; `sda` (Seagate Expansion, 1.8 TB) carries
   the `media` storage. Largest pool consumers by real usage are
   `pve/root` 37.55 GB, `vm-211-disk-0` 49.42 GB, `vm-220-disk-1`
   49.16 GB (NFS), `vm-212-disk-0` 40.62 GB, `vm-213-disk-0` 38.29 GB.
   Both targets are `rotational=1` over USB, so this trades capacity for
   IOPS — on a host whose `iowait` problem was I/O in the first place.
2. **Replace or extend the NVMe.** This addresses capacity and the
   172 GB/day wear figure together, and is the only option that does not
   move latency-sensitive I/O onto spinning USB disks.

Either way, the load-bearing detail is the same: **this pool has no
headroom, and every future storage decision has to treat TRIM as load-
bearing rather than housekeeping.**
