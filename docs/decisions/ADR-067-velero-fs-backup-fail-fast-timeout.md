# ADR-067: Velero fails fast on a stuck volume upload

**Date:** 2026-11-15
**Status:** Accepted

## Context

On 2026-10-20 `daily-offsite` ended `PartiallyFailed` with `timed out waiting for all
PodVolumeBackups to complete`. One `PodVolumeBackup` (an empty `tmp` emptyDir of `mealie`)
sat `InProgress` against `r2-offsite` for four hours. The pod, its node and both backup
storage locations were healthy, and the local `daily-backup` one hour later backed up the
same volume in seconds. The kopia uploader to R2 had hung, most likely after the
cluster-wide node-agent restart the evening before orphaned its in-flight work.

Two Velero server defaults turned that into a four-hour stall:

- `--fs-backup-timeout`, the budget for pod volume backups, defaults to 4h.
- `--default-item-operation-timeout`, the wait on asynchronous item operations, defaults
  to 4h.

ADR-075 later changed what the offsite backup carries (emptyDirs and raw Postgres
directories skipped, `pg_dump` archives instead), but both schedules still use kopia
filesystem backups, so the same hang can still hold either of them for four hours.

## Decision

Set both server flags to 45 minutes in `kubernetes/system/velero/application.yml`.

The slowest healthy volume across the last week of `daily-backup` and `daily-offsite` runs
took 134 seconds (the Prometheus TSDB on the local leg); whole runs take 2 to 7 minutes.
45 minutes leaves a wide margin for a slow night while bounding a hung upload to well under
an hour. The flags are global, so the local leg is bounded as well, which fits the same
numbers.

## Consequences

- A hung upload fails its backup within 45 minutes instead of four hours.
  `VeleroBackupPartialFailure` alerts on the result, so the failure is visible the same
  morning.
- A volume that genuinely needs more than 45 minutes would now fail. None comes close; if
  one ever does (a large new PVC), raise the timeout rather than drop it.
- The flags do not repair a hung kopia uploader; they only bound how long it can block
  the backup.
