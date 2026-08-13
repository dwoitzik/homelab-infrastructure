# Immich

Self-hosted photo/video library with ML-based search and face recognition.

## Storage — three different pieces, three different risk profiles

- **`immich-library` (the actual photos/videos, 400Gi): a static PV pointing directly at
  the USB-backed NFS export `10.0.20.100:/usb-immich-library`.** Same pattern as Garage's
  bulk data — physically independent of the k3s cluster, never at risk from a cluster
  rebuild. Write-once/read-many workload, a good fit for USB flash; databases must never
  go here (see the PVC's own comment for the benchmarked read/write numbers this decision
  was based on).
- **`immich-db`/`immich-db-pg16` (Postgres, metadata/faces/albums): `nfs-client`.** This
  *does* need restoring after a cluster rebuild.
- **`immich-ml-cache` (downloaded ML models, ~3GB): `nfs-client`, but re-downloadable —
  not worth restoring, just let it repopulate.

## How to restore the database — Immich has its own backup, use it

Immich runs a **daily in-app database dump** (`pg_dump`, gzipped) that writes straight
onto the same USB storage as the library itself
(`immich-library/backups/immich-db-backup-<timestamp>-<version>.sql.gz`). Because this
lives on the untouched USB mount, not inside the k3s cluster's own PVC layer, it survives
independently of whatever happened to the cluster. This is the primary restore path —
don't assume the database is unrecoverable just because it's not in the standard
Tier-1 k3s-local-path dataset map; check here first.

Restore: create the target database fresh (`createdb -U immich immich` if the CNPG/
Postgres image's own bootstrap didn't already), copy the most recent `.sql.gz` into the
postgres pod, `gunzip -c | psql -U immich -d immich`. Verified 2026-08-13: 24,668 real
assets, 3 real users recovered this way — a genuine full recovery, not a fresh-empty
deploy with photos but no history.

## Known gotchas

- Major Postgres version bumps (this repo has been through 14→16) need a real dump/
  restore, not a bare image swap — the old PVC is kept declared-but-unused in git as a
  rollback path rather than deleted immediately after a migration.
- Under heavy simultaneous cluster load (e.g. a full ApplicationSet bulk-deploy), a fresh
  Postgres instance's `initdb` can get interrupted before it finishes creating the target
  database or writing a permissive `pg_hba.conf` — if a brand-new instance won't accept
  connections, check for a role that exists but no matching database, or a `pg_hba.conf`
  missing a pod-network rule, before assuming something is actually broken.
