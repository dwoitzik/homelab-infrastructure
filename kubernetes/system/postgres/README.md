# postgres

CloudNativePG `Cluster` resources for every Postgres-backed app: Authelia
(`cluster.yml`), Firefly III (`cluster-firefly.yml`), n8n (`cluster-n8n.yml`), Scanopy
(`cluster-scanopy.yml`) and Matrix Synapse (`cluster-synapse.yml`). Each is
single-instance (`instances: 1`): this is a single-physical-host homelab, CNPG's
multi-replica failover doesn't add real resilience here, just complexity.

Every Cluster sets `priorityClassName: node-pinned-stateful` (ADR-083): its data sits on
a `local-path` volume on one node, so after a cold start the instance must be able to
preempt movable pods there. CNPG does not restart instances when only this field changes;
delete the `postgres-*-1` pod once to apply it.

## Backups

1. **Barman Cloud plugin** (`kubernetes/system/plugin-barman-cloud`, ADR-081):
   continuous WAL archiving plus a daily base backup (`scheduled-backup.yml`, 02:00 to
   02:40, `method: plugin`) to Garage at `s3://cnpg-backups/<name>/postgres-<name>/`.
   Each Cluster names its target in `spec.plugins[].parameters.barmanObjectName`; the
   target itself is an `ObjectStore` of the same name in `object-stores.yml`, which
   also holds the 7d retention and the sidecar's resources. The paths are the ones the
   old in-tree `barmanObjectStore` used, so backups from before the switch are in the
   same catalog.
2. **Logical dumps** for the offsite copy (ADR-075, `kubernetes/system/velero/offsite-db-dumps.yml`).
3. **Velero/PBS**, covering the underlying PVC at the filesystem level, timed to run
   *after* the barman base backups (03:00+).

`backup-config.yml` holds the region (`homelab`) barman sends to Garage;
`cnpg-garage-backup` (out-of-band) holds the S3 keys.

Check the state of one cluster:

```bash
kubectl get cluster -n database postgres-<name> \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'   # ContinuousArchiving=True
kubectl -n database get objectstore postgres-<name> -o jsonpath='{.status}'   # recovery window
kubectl get backup -n database --sort-by=.metadata.creationTimestamp | tail
```

On-demand backup:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-<name>-manual-<date>
  namespace: database
spec:
  cluster:
    name: postgres-<name>
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

Alerts: `CNPGBackupTooOld` / `CNPGBackupCatalogUnknown`
(`monitoring/silent-failure-alerts.yml`, plugin metric
`barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`) and
`PostgresWALArchivingBacklog*` (`monitoring/postgres-alerts.yml`). Every cluster has a
PodMonitor in `postgres-monitoring.yml`.

### Adding a cluster

Add an `ObjectStore` (copy one in `object-stores.yml`, new `destinationPath`, keep the
sync-wave `-1` and the sidecar's cpu and memory limits: Kyverno rejects the pod without
them), the `spec.plugins` entry on the Cluster, a ScheduledBackup with `method: plugin`
and a PodMonitor. Add the new file names to `postgres-cluster-application.yml`'s
include list.

## User Secrets — `.example` files

`user-n8n.yml.example` / `user-synapse.yml.example` / `user-scanopy.yml.example` are
templates, not applied directly — the real Secret (matching password already in
Vault/the app's own config) is created out-of-band per `cluster.yml`'s own
migration-steps comment, never committed with real values.

## How to restore

CNPG restores into a **new** Cluster; it never overwrites a running one. Restore next to
the live cluster first, check the data, then decide whether to point the app at it or
to replace the original (delete it and recreate it under its old name the same way).

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-<name>-restore
  namespace: database
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.2
  storage:
    size: 5Gi
    storageClass: local-path
  resources:            # Kyverno needs cpu and memory limits
    requests: {cpu: 50m, memory: 128Mi}
    limits: {cpu: 250m, memory: 256Mi}
  bootstrap:
    recovery:
      source: origin
      # recoveryTarget:
      #   targetTime: "2026-11-17 19:55:00+00"   # omit for the latest point
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: postgres-<name>   # read-only use of the existing ObjectStore
          serverName: postgres-<name>
```

The restored cluster does not archive. Before it archives to the same bucket, give it
its own `ObjectStore` path (or a different `serverName` plugin parameter): the plugin
refuses to archive into a server directory that already holds WAL.

If the whole cluster was rebuilt, ArgoCD brings the plugin, the `ObjectStore`s and empty
Clusters (`bootstrap.initdb`) back first. Hibernate or delete the empty Cluster, create
the restore Cluster under the original name with the spec above plus its
`spec.plugins` entry pointing at a fresh path, and move the Git manifest to match before
re-enabling sync. `DISASTER-RECOVERY.md` section 5a has the full sequence.

## Dependencies

CloudNativePG operator, Barman Cloud plugin, cert-manager (plugin TLS), Garage (backup
target).
