# ADR-067: Fail fast on a stuck offsite volume upload

## Status

Accepted and applied, 2026-10-20.

## Context

`daily-offsite` (Velero, `Schedule/daily-offsite` → Cloudflare R2) reported
`PartiallyFailed` on 2026-10-20 with a single error:

```text
timed out waiting for all PodVolumeBackups to complete
```

One `PodVolumeBackup` — pod `mealie`'s `tmp` emptyDir, on `vm-srv-k3s-13` —
sat `InProgress` from 04:03 until the backup's 4-hour item-operation budget
expired at 08:00. The run took 4 hours where the two preceding nights took
8 and 13 minutes.

What it was *not*:

- **Not the pod or its data.** `mealie`'s `/tmp` was empty (4 KiB) — there was
  nothing to upload.
- **Not the node or the cluster.** `daily-backup` (the local Garage leg, same
  node, same pod, one hour later) completed cleanly at 08:06, including a
  `mealie` volume.
- **Not an unreachable backend.** Both `BackupStorageLocation`s reported
  `Available`.

The one thing that distinguished the stuck item from the healthy one was the
**storage location**: the stalled upload was going to `r2-offsite`; the one
that worked was going to `default` (local Garage). The uploader held the kopia
data path open against R2 for the full 4 hours and never returned, long after
no process was doing any work for it.

Two defaults made that survivable-to-fail-loudly into a 4-hour stall that also
left a zombie behind:

- `--fs-backup-timeout` — the pod-volume filesystem backup budget — defaults
  to 4 hours.
- `--default-item-operation-timeout` — how long the parent backup waits on
  async item operations — also defaults to 4 hours.

Neither was set here, so both inherited. A hung uploader therefore cost the
full window, and the orphaned `PodVolumeBackup` object stayed `InProgress`
indefinitely after the backup was already marked failed.

A contributing factor: all three node-agent pods restarted cluster-wide on
2026-10-19 at 17:11 UTC (exit 255, `Unknown` — a k3s/containerd-level event),
and again roughly 17 hours later. A node-agent restart mid-upload orphans
in-flight kopia work; this run created a fresh uploader afterward that then
never made progress against the R2 repo.

## Decision

Set both timeouts to **45 minutes** in `kubernetes/system/velero/application.yml`:

```yaml
- --fs-backup-timeout=45m
- --default-item-operation-timeout=45m
```

45 minutes is comfortably above a healthy upload — nightly offsite runs finish
each volume in well under 15 minutes, and the whole run in 8–13 minutes — while
still being short enough that a genuinely hung uploader fails fast instead of
burning four hours and leaving an orphan.

This does not repair a stuck upload; it bounds the damage one can do. The
`r2-offsite` kopia repositories carry a degraded-index warning ("too many index
blobs"), which is the plausible reason a repository open/scan was slow enough to
stall, but the evidence for that being *the* cause here is circumstantial (the
pod, its data, and the local leg were all healthy) and is tracked separately
rather than fixed blind in this change — see "Open" below.

## Consequences

- A hung volume upload now surfaces as a failure within 45 minutes, not 4
  hours, and no longer leaves a zombie `PodVolumeBackup` object for the next
  run to trip over.
- The real 4-hour safety margin for an unusually large or slow volume is
  given up. Accepted because no volume in scope backs up anywhere near that
  slowly, and the failure mode of a too-short timeout (a retried volume, a
  visible error) is strictly better than the one it replaces (a silent stall
  plus an orphan).
- This is a global Velero setting, not offsite-specific. The local
  `daily-backup` leg is affected too; it also finishes each volume in minutes,
  so the same bound is appropriate there.

## Open

- **`r2-offsite` kopia index-blob degradation.** The R2 repos log "Found too
  many index blobs" during maintenance. This is a known consequence of the
  lowered maintenance frequency (`--default-repo-maintain-frequency=24h`,
  itself a deliberate REL-044 trade against NVMe load from hourly kopia jobs).
  The correct fix — a middle frequency, or forcing a full maintenance pass —
  needs measurement of both the index-blob count trend and the NVMe impact
  before it is changed; doing it blind would re-introduce the load REL-044
  existed to remove. A follow-up, not part of this change.
- **No alerting on a stuck/`PartiallyFailed` offsite run.** This was found by
  reading `kubectl get backups`, not by an alert. A `PartiallyFailed` offsite
  backup should page the same way a failed local one would. Follow-up.
