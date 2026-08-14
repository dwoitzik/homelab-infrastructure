# postgres

CloudNativePG `Cluster` resources for every Postgres-backed app: Authelia
(`cluster.yml`), n8n (`cluster-n8n.yml`), Matrix Synapse (`cluster-synapse.yml`). Each
is single-instance (`instances: 1`) — this is a single-physical-host homelab, CNPG's
multi-replica failover doesn't add real resilience here, just complexity.

## Backups — two layers

1. **Continuous WAL archiving** to Garage S3 (`.spec.backup.barmanObjectStore` on each
   Cluster), plus a daily `ScheduledBackup` (`scheduled-backup.yml`, 02:00) for a real
   base backup to restore from via barman — a Cluster's PVC alone isn't restorable
   through barman without one.
2. **Velero/PBS**, covering the underlying PVC at the filesystem level, timed to run
   *after* the barman base backup completes (03:00+) so they don't race over the same
   NFS-backed volume.

`backup-config.yml` — the Secret barman uses to reach Garage's S3-compatible API
(region `homelab`, matching every other Garage-backed backup in this repo).

## User Secrets — `.example` files

`user-n8n.yml.example` / `user-synapse.yml.example` are templates, not applied
directly — the real Secret (matching password already in Vault/the app's own config)
is created out-of-band per `cluster.yml`'s own migration-steps comment, never committed
with real values.

## How to restore

CNPG operator healthy first, then each Cluster bootstraps fresh and CNPG restores from
the barman base backup + WAL archive automatically if `bootstrap.recovery` is
configured (vs. `bootstrap.initdb` for a from-scratch cluster — check each Cluster
resource for which mode it's in before assuming data survives a delete).

## Dependencies

CloudNativePG operator, Garage (backup target).
