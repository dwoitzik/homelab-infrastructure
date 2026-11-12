# ADR-075: Offsite backup carries pg_dump archives, not raw database directories or emptyDirs

**Date:** 2026-11-12
**Status:** Accepted

## Context

`r2-usage-guard` paused `daily-offsite` on 2026-11-12 at 9.13 GiB of its 9 GiB cap, three
weeks after ADR-062 shortened the offsite TTL to 3 days for the same reason. Shortening the
TTL again would not have helped. The last offsite backup (`daily-offsite-20261111040018`)
read 11 GiB of raw volume data, and almost all of it should not have been there:

| Category | Raw bytes per backup |
|---|---|
| Raw Postgres data directories (5 CNPG `pgdata`, `immich-postgres` `db`, paperless and nextcloud Postgres `data`) | 8.8 GiB |
| emptyDir volumes (dex `static-files`, `tmp`, caches, sockets, `shm`) | 0.43 GiB |
| Everything else (nextcloud data and html, vault, redis, small app volumes) | 1.78 GiB |

The Postgres directories are mostly WAL: each CNPG cluster keeps about 577 MiB of `pg_wal`
for a database of 10 to 15 MB, and immich's 2.3 GiB directory holds a 523 MB database.
WAL segments are rewritten constantly, so kopia found little to deduplicate between days,
and Velero's kopia uploader stores data uncompressed (`CompressorName: "none"` in
`pkg/uploader/kopia/snapshot.go`, v1.14.1).

A file-level copy of a running Postgres is also not a consistent backup: kopia reads the
files one after another while the server keeps writing. CNPG's barman backups are
consistent, but they go to the local Garage bucket, so the offsite tier had no restorable
database copy at all.

## Decision

1. **emptyDirs are skipped offsite.** `daily-offsite` references the Velero volume policy
   ConfigMap `velero/offsite-volume-policy` (`volumeTypes: [emptyDir]`, action `skip`).
   In Velero 1.14 the volume policy is evaluated for fs-backup pod volumes before the
   `defaultVolumesToFsBackup` fallback (`internal/volumehelper/volume_policy_helper.go`).
2. **Raw Postgres directories are not backed up offsite.** The 1.14 volume policy can only
   match capacity, storage class, NFS/CSI source and volume type, none of which tells the
   database PVCs apart from the rest. The Schedule's `labelSelector` leaves out the
   database pods instead, which also skips their volumes: CNPG instance pods
   (`cnpg.io/podRole=instance`), CNPG data/WAL PVCs (`cnpg.io/pvcRole`), and the pods
   labelled `app` in `immich-postgres`, `postgres-paperless`, `postgres-nextcloud` (only
   the pods carry those labels; the StatefulSets, Services and PVC manifests are still
   backed up).
3. **Databases are backed up as `pg_dump` archives.** A `pg-dump` Deployment in `database`
   and in `apps` (`kubernetes/system/velero/offsite-db-dumps.yml`) idles with a
   `local-path` PVC `pg-dumps`. Its Velero pre-backup hook runs `pg_dump --format=custom`
   for every database of its namespace, checks each archive with `pg_restore --list` and
   only then replaces the previous file. The same backup then copies the PVC. A failed
   database keeps its previous dump, the hook exits non-zero, and the backup ends
   `PartiallyFailed`, which `VeleroBackupPartialFailure` alerts on.
4. **TTL stays 72h.**

The hook was chosen over a CronJob that runs before 04:00: a hook dumps at exactly the time
of the backup that copies the dumps, so no clock coupling, and a dump failure surfaces on
the backup itself. The local `daily-backup` runs the same hook, so the local tier gains
consistent dumps on top of its raw copies and the CNPG barman backups; its scope is
otherwise unchanged.

All dumps use the `postgres:18.4-alpine` client, the newest server major in use. pg_dump
18 dumps the 16 (immich), 17 (CNPG) and 18 servers, and the archives need pg_restore 18 to
read them, so restores run from that same image.

Vault is left as it is. Its `data` volume (176 MiB raw, BoltDB pages rewritten in place)
is the largest daily delta after this change, but a `vault operator raft snapshot` needs a
Vault token with snapshot rights in the backup path, which is a separate change.

## Expected size

Per backup about 1.9 GiB raw: 1.78 GiB of remaining volumes plus about 100 MB of dumps
(immich 97 MB, the rest under 1 MB each). Most of that is nextcloud data and html, which
deduplicates between days. The daily new content is roughly vault (0.18 GiB), the immich
dump (about 0.1 GiB, compressed, so it does not deduplicate) and small app changes, about
0.3 to 0.4 GiB. With three retained backups and up to two days before kopia maintenance
deletes expired content, steady state is about 3.5 GiB, well under the 9 GiB cap. The
measured value after the first run is recorded in `kubernetes/system/velero/README.md`.

## Consequences

- Restoring a database offsite is no longer "restore the PVC". The database comes up
  empty from Git and the dump is loaded with `pg_restore`, see `DISASTER-RECOVERY.md`.
  The offsite tier now has a consistent copy, which it did not have before.
- The offsite restore point of a database is the dump taken at backup time, not
  point-in-time. Local PITR is still available from CNPG's barman backups in Garage.
- A new database must be added to `DUMP_TARGETS` in `offsite-db-dumps.yml`, and a new
  plain Postgres StatefulSet to the Schedule's `labelSelector`; otherwise it is either
  missing offsite or copied raw again.
- The old raw blobs leave R2 only after the backups that reference them expire and kopia
  full maintenance has run twice, so usage drops over the following days, not at once.
