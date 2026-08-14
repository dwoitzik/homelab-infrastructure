# Firefly III

Personal finance manager. Own `postgres-firefly` StatefulSet (`database` namespace),
not CNPG — plain Postgres.

## Storage

`nfs-client` PVCs: `firefly-data` (app state/attachments) and `postgres-firefly-data`
(the database itself, in `database` namespace).

## How to restore

Standard PVC swap-restore: scale `postgres-firefly` to 0, mount the PVC via a
throwaway pod, copy preserved data in, scale back up.

## Known gotchas

- Under simultaneous heavy cluster load (e.g. a full bulk app rollout), this Postgres'
  first-boot `initdb` can get interrupted before finishing — leaves a role but no
  target database, or a database with no `pg_hba.conf` rule for pod-network
  connections (only loopback). Recognizable by `FATAL: database "firefly" does not
  exist` or `no pg_hba.conf entry` errors on a *freshly created* instance (not a
  restored one). Fix: `createdb -U firefly firefly` via local socket, then append a
  broad `host all all <pod-cidr> scram-sha-256` line to `pg_hba.conf` and
  `SELECT pg_reload_conf();` — no data lost, just an interrupted bootstrap.
