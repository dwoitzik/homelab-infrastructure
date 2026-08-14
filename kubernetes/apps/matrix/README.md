# Matrix (Synapse + Element)

Self-hosted Matrix homeserver (Synapse) with a web client (Element). Not in the brief's
original Tier-1 dataset list, preserved anyway per the recovery's own "preserve first"
principle.

## Storage

Postgres via CloudNativePG — `kubernetes/system/postgres/cluster-synapse.yml`, **not**
`kubernetes/apps/matrix/`. Same reasoning as n8n's README: this lives alongside the other
CNPG clusters under `kubernetes/system/postgres/`, outside the ApplicationSet's
auto-discovered path, and needs applying explicitly.

## How to restore

Standard CNPG hibernate → swap PVC contents → un-hibernate. Pre-disaster usage was
genuinely low (`users`: 0 rows in the restored data) — matches what Phase 1's own data
audit already found and recorded, not a sign of a bad restore.

## Known gotchas

- **If a restore looks like it landed the wrong (much larger) amount of data than
  expected, check `pg_wal/` before assuming the restore is corrupt.** This instance's
  data directory came out to ~18GB despite the actual database content being ~14MB — the
  difference was accumulated WAL segments, not real data. Confirm via `\l+` in `psql`
  (per-database size) rather than `du -sh` on the whole PVC.
- Continuous WAL archiving to Garage needs the same `cnpg-garage-backup`/
  `cnpg-backup-config` secrets as n8n (see its README) — shared credentials, one Secret
  covers both clusters.
