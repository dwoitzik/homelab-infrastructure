# Velero

Kubernetes-native backup: cluster resource manifests + PV data (via Kopia FS-backup),
to Garage S3 locally and Cloudflare R2 offsite. This is the backup layer proven to
actually restore during the 2026-08-13 disaster recovery — not just scheduled, tested.

## `upgradeCRDs: false` — never change this

Bitnami pulled every tagged `kubectl` image from Docker Hub, and every alternative
tried (`alpine/k8s`, `registry.k8s.io/kubectl`, `ghcr.io/bitnami`) is broken for this
specific use (musl/distroless/403). Helm installs the CRDs from the chart natively —
`upgradeCRDs` is redundant when it works and breaks the whole release when it doesn't.
Confirmed the hard way; do not re-enable it "to be safe."

## Two-tier backup: local + offsite (3-2-1)

- **Local** (`schedule.yml`, `daily-backup`, 03:00) — everything, to Garage S3
  (`http://garage.apps.svc.cluster.local:3900`), full `defaultVolumesToFsBackup` PVC
  coverage. Fast restore path for the common case (a bad deploy, an accidental
  deletion), but Garage lives on the same physical host as everything else — no
  protection against total host loss.
- **Offsite** (`offsite-schedule.yml`, `daily-offsite`, 04:00, one hour after local) —
  Cloudflare R2, critical namespaces only (`apps`, `vault`, `database`, `argocd`),
  large low-value volumes (media, Prometheus/Loki/Tempo data) excluded by label. 7-day
  TTL. This is the actual disaster-recovery tier — survives losing the physical host
  entirely, which the local tier by itself cannot.

`r2-backuplocation.yml` — the R2 `BackupStorageLocation`; credentials via
`r2-secret.yml.example` (template, real values out-of-band, never committed).

## `defaultVolumesToFsBackup` — the gap that bit this repo once already

A prior incident (2026-06-19, referenced in `ROADMAP.md`) found `daily-backup` missing
this flag: backups completed "successfully" but only captured k8s manifests, not real
PVC data. Fixed and verified with a real Kopia Pod Volume Backup test run. Both
schedules in this directory now set it explicitly — don't remove it without a new
verified restore test.

## How to restore

See `docs/backup-strategy.md` / `DISASTER-RECOVERY.md` for the full procedure. In short:
`velero restore create --from-backup <name>`, verify data in place afterward — this
repo's own non-negotiable rule (never trust a backup that hasn't been restore-tested).

## Dependencies

Garage (local target), a working R2 credential (offsite target).
