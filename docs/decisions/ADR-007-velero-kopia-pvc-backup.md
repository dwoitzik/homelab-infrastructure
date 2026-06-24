# ADR-007: Velero + Kopia for PVC-level backup

**Date:** 2026-06-19
**Status:** Accepted

## Context

The `nfs-client` StorageClass (see ADR-005) has no CSI snapshotter — there is no
volume-snapshot mechanism available for any PVC backed by it. Without filesystem-level
backup, Velero would only ever capture Kubernetes object manifests (Deployments,
Services, PVC definitions), not the actual data inside those volumes.

This gap was live for an unknown period: the `daily-backup` Schedule
(`kubernetes/system/velero/schedule.yml`) ran every night, completed "successfully," and
gave no indication anything was wrong — `velero backup describe` simply showed
`<none included>` under Pod Volume Backups, which nobody was checking. It was only
caught on 2026-06-19, at which point Postgres, Vaultwarden, Paperless, and Nextcloud had
all been "backed up" for some time without a single byte of their actual data anywhere
but the live PVC.

## Decision

Set `defaultVolumesToFsBackup: true` on the Velero `Schedule` resources
(`schedule.yml`, `offsite-schedule.yml`), enabling Velero's file-system backup path
(Kopia, via the `node-agent` DaemonSet deployed by the Velero Helm chart with
`deployNodeAgent: true`) for every pod volume by default.

## Reasons

`defaultVolumesToFsBackup` is the only viable PVC backup mechanism given the storage
layer: there is no CSI snapshot capability to fall back on, and per-volume opt-in
annotations are an easy way to silently exclude a volume by forgetting to add one —
opt-out (default true, exclude by exception) is safer for a homelab where new PVCs get
added without a backup review step. Kopia (Velero's built-in FS-backup engine since
v1.10) needs no extra component beyond the node-agent already required for this feature.

## Trade-offs

- File-system backup is slower and more I/O-intensive than a true CSI snapshot — full
  read of PVC contents on every backup run, not a copy-on-write snapshot
- Silent failure mode risk remains structural, not just historical: a "Completed" backup
  status does not by itself prove data was captured. The only real verification is
  `velero backup describe <name> --details | grep -A5 "Pod Volume Backups"` — this is now
  documented as a required check in `docs/backup-strategy.md` any time the Schedule is
  touched, but it is a manual step, not an automated gate
- Increases backup duration and Garage S3 storage usage substantially since every byte of
  every PVC is read and (incrementally) uploaded each run, versus manifest-only backups

## Consequences

Both `daily-backup` (in-cluster, Garage S3, 30-day TTL) and the offsite `r2-offsite`
schedule carry `defaultVolumesToFsBackup: true`. `docs/backup-strategy.md` documents the
2026-06-19 incident explicitly so the failure mode and its verification command aren't
lost to institutional memory. Any new Schedule resource added in the future must include
this field — there is no test or CI check enforcing it, so it relies on this ADR and the
backup-strategy doc being read before editing Velero config.
