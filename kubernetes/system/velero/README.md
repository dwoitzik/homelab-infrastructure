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
  large low-value volumes (media, Prometheus/Loki/Tempo data) excluded by label. 3-day
  TTL (kept short so `r2-usage-guard`'s free-tier cap doesn't pause the schedule — see
  ADR-062). This is the actual disaster-recovery tier — survives losing the physical host
  entirely, which the local tier by itself cannot.

### What the offsite backup contains (ADR-075)

- **No emptyDirs.** `offsite-volume-policy` (Velero volume policy, referenced by the
  Schedule's `resourcePolicy`) skips every emptyDir.
- **No raw Postgres directories.** The Schedule's `labelSelector` leaves out the CNPG
  instance pods and data PVCs and the `immich-postgres`, `postgres-paperless` and
  `postgres-nextcloud` pods, so their volumes are not copied.
- **pg_dump archives instead** (`offsite-db-dumps.yml`). A `pg-dump` pod in `database`
  and in `apps` runs `pg_dump --format=custom` for each database as a Velero pre-backup
  hook, into its `pg-dumps` PVC (`/dumps/<db>.dump`, `/dumps/.last-run`). A failed dump
  keeps the previous file and marks the backup `PartiallyFailed`. The local schedule runs
  the same hook, so it carries the dumps too.

Adding a database: add it to `DUMP_TARGETS` (and its `<NAME>_*` env) in
`offsite-db-dumps.yml`; a new plain Postgres StatefulSet also goes into the Schedule's
`labelSelector`.

Check after any change to the offsite scope, before trusting it:

```bash
kubectl get podvolumebackups -n velero -l velero.io/backup-name=<backup> \
  -o custom-columns=POD:.spec.pod.name,VOL:.spec.volume,BYTES:.status.progress.totalBytes
```

No `tmp`/`cache`/`shm` volumes and no `pgdata`/`db` volumes of the database pods should
be listed, and both `pg-dump` pods' `dumps` volumes should.

Measured on the first backups with this scope (2026-11-12): 27 PodVolumeBackups, 1.85 GiB
read per backup (was 11 GiB with 124), of which nextcloud data and html are 1.5 GiB and
the dumps 100 MB. The first backup added 0.24 GiB to R2, a second one minutes later
0.05 GiB. R2 held 8.3 GiB afterwards, most of it raw database content of the older
backups, which leaves R2 once they expire (TTL 72h) and kopia maintenance has run.

### `r2-usage-guard` and Git

The guard pauses `daily-offsite` by patching `spec.paused` live and never resumes it.
`offsite-schedule.yml` does not set `paused`, so an ArgoCD sync leaves the live value
alone in both directions. Resuming is a manual
`kubectl patch schedule.velero.io daily-offsite -n velero --type merge -p '{"spec":{"paused":false}}'`
once R2 usage is back under the cap.

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
