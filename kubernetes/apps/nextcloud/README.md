# Nextcloud

Files/CalDAV/CardDAV — deployed, but **confirmed never actually put into use**
(operator-confirmed directly during the 2026-08-13 recovery, after an exhaustive check
across every plausible data location turned up nothing). Not a data-loss situation.

## Storage

`nfs-client` PVCs: `nextcloud-data` (files) and `nextcloud-db-data-pg18` (Postgres,
own StatefulSet, not CNPG). A prior PG14→16→18 migration history exists in the
manifest's own comments — old PVCs are kept declared-but-unused as a rollback path
rather than deleted immediately after each migration.

## Known gotchas

- **First-ever boot is slow** (runs Nextcloud's own install/migration sequence before
  Apache serves anything) — under heavy simultaneous cluster load this can exceed a
  tightly-set liveness probe's grace window, causing a crash-loop that never actually
  finishes installing (each restart kills it mid-install, the next attempt starts over).
  `readinessProbe`/`livenessProbe` `failureThreshold` should stay generous for this
  reason even though steady-state restarts (already installed) come up fast regardless.
- If a crash-loop leaves a stale `nextcloud-init-sync.lock` file in `/var/www/html`,
  every subsequent boot waits on it indefinitely ("Another process is initializing
  Nextcloud") even though nothing is actually still running — remove it manually
  (`rm /var/www/html/nextcloud-init-sync.lock`) if this happens.
- Postgres 18's image needs a single mount at `/var/lib/postgresql` (not the old
  16-style `/var/lib/postgresql/data` + subPath) — see the manifest's own comment,
  `docker-library/postgres#1259`.
- Redis here runs with persistence explicitly disabled
  (`redis-server --save "" --appendonly no`) — a prior real incident had it silently
  refusing all writes (including PHP session writes) after repeatedly failing to write
  RDB snapshots to the read-only root filesystem, which looked like an unrelated
  capabilities/auth problem at first.
