# ADR-052: The PBS health check was reading backup history as if it were the current fleet

**Status:** Accepted and applied, 2026-10-03

## Context

At 04:35 on 2026-10-03, in the same window as the Prometheus restart storm in
ADR-051, the PBS backup health check fired:

```text
VMID 110:  latest backup is 1262h old - missing or failed
VMID 9211: latest backup is 1034h old - missing or failed
VMID 9213: latest backup is 1033h old - missing or failed
```

Taken at face value that reads as a month-long backup outage. It is not. Every
currently configured guest had a snapshot from that morning, taken between
01:00 and 02:16 UTC by the nightly job:

```text
100  0d  8778MiB   200  0d  36155MiB   201  0d  23033MiB   202  0d   7201MiB
203  0d   4132MiB  204  0d  17748MiB   205  0d   5494MiB   211  0d 131072MiB
212  0d 122880MiB  213  0d 122880MiB   220  0d   1078MiB   301  0d   4712MiB
302  0d  18190MiB  9200 0d  37251MiB
```

VMIDs 110, 9211 and 9213 do not exist. `qm list` and `pct list` show a fleet of
211, 212, 213, 100, 200–205, 220, 301, 302, 9000 and 9200. The three failing
VMIDs are deleted guests whose last snapshots survived in PBS — 17 orphaned
snapshots in total, the oldest from 2026-08-11.

## Root cause

The check derived the guest list from the datastore rather than from Proxmox:

```bash
ALL_VMIDS=$(pvesm list "$STOREID" | awk 'NR>1{print $5}' | sort -u)
```

`pvesm list` returns everything the datastore holds, which accumulates deleted
guests indefinitely. Its own comment claimed the opposite — "the real, current
fleet, not a hardcoded list that would drift" — so the drift was invisible on
inspection. Any guest removed from Proxmox but not yet pruned from PBS becomes a
permanent critical alert, which trains the reader to ignore the alert.

Three further defects in the same block:

- `tail -1` selected the last line for a VMID rather than the newest by the
  timestamp inside the volid. `pvesm list` promises no ordering, so this could
  report a fresh guest as stale.
- `pvesm list` was re-run once per VMID — a full datastore listing inside the
  loop, quadratic in fleet size.
- A live guest with no backup at all was skipped by `[ -z "$LATEST" ] && continue`,
  the inverse of the intended failure: the exact case that should page was
  silently ignored.

## Fix

Enumerate the fleet from `qm list` and `pct list`, and take a single `pvesm`
pass keyed on the timestamp inside each volid. A live guest with no snapshot is
now reported rather than skipped.

`max_age_hours` stays at 26. The job runs `*-*-01/2`, i.e. every other day, so
the worst-case gap between runs is 48h; 26 is a real staleness signal against
that schedule rather than a round number.

## Verification

Rendered the template and exercised it against stubbed `qm`/`pct`/`pvesm`, with
the fleet printed on every case so a vacuously-passing run cannot be mistaken
for a healthy one:

| case | expected | result |
|---|---|---|
| everything fresh | 1 | 1 |
| 211 backup 63 days old | 0 | 0 |
| 100 only 1KiB, below the 100MiB floor | 0 | 0 |
| 211 newest snapshot not the last line | 1 | 1 |
| 9000 present in PBS, absent from the fleet | 1 | 1 |
| 777 in the fleet, never backed up | 0 | 0 |
| 211 in the fleet, no snapshot in PBS | 0 | 0 |

The fourth case is the `tail -1` regression: with the fresh snapshot listed
first and the stale one last, the old code would have raised a 13-day-old
false alarm. Then ran it unmodified against the real host: 14 live guests,
`pve_pbs_backup_healthy 1`, no failures, no ntfy.

## Related: what actually caused the host load

The same investigation explains ADR-051. `jobs.cfg` schedules `nightly-backup`
for `*-*-01/2 03:00:00`, and on 2026-10-03 the snapshots above were written
between 01:00 and 02:16 UTC — 03:00 to 04:16 local. The `pve host: Load 38.96`
and `Load 56.36` alerts fired at 03:15 and 03:37 local, inside that window. On a
16-core host, load 56 is the nightly backup, not a mystery. Prometheus was being
restarted by its own liveness probe because of it.

## Not addressed here

- 17 orphaned snapshots belonging to the three deleted guests remain in PBS.
  Removing them is a destructive datastore operation and is left for a separate
  decision with its own restore verification.
- The `pve host: Load >= 30` watchdog threshold is crossed routinely by this
  same nightly job. Either the threshold or the job's aggressiveness needs to
  change; raising the threshold alone would hide genuine load problems.
