# ADR-081: CNPG backups run through the Barman Cloud plugin, on the same bucket paths

**Date:** 2026-11-17
**Status:** Accepted, applied

## Context

All five CloudNativePG clusters in `database` (authelia, firefly, n8n, scanopy, synapse)
archived WAL and took base backups with the operator's in-tree
`spec.backup.barmanObjectStore`, to Garage at `s3://cnpg-backups/<name>`. CNPG deprecated
that method in 1.26, and the admission webhook on 1.30.1 warns that it is removed in
1.31.0. Renovate held the operator chart below 0.30 (#1215) so an operator bump could
not silently turn off backups for every database.

The replacement is the Barman Cloud plugin (`plugin-barman-cloud`, CNPG-I). It runs as
its own Deployment next to the operator and injects a sidecar into each instance pod.
Plugin 0.16 needs operator 1.30 or newer and cert-manager for its mTLS certificates.

Options considered:

1. **Plugin, same bucket paths.** Translate each `barmanObjectStore` block 1:1 into an
   `ObjectStore` and keep `destinationPath`. The plugin's default `serverName` is the
   Cluster name, which is what the in-tree method used, so it writes into the existing
   catalog.
2. **Plugin, fresh paths.** Cleaner separation between old and new archives, but the
   seven days of backups and WAL taken in-tree would sit in a catalog no `ObjectStore`
   points at, and a restore from them would need a second, temporary `ObjectStore`.
3. **Stay on 1.30.** Only defers the work and leaves the operator pinned.

## Decision

Option 1. `plugin-barman-cloud` (chart 0.9.0, plugin 0.16.0) is installed by its own
ArgoCD Application in `cnpg-system`. Each cluster has an `ObjectStore` of the same name
in `kubernetes/system/postgres/object-stores.yml` with the old path, credentials, gzip
compression and the 7d retention that used to sit on the Cluster. Each Cluster lists the
plugin under `spec.plugins` with `isWALArchiver: true`; each ScheduledBackup uses
`method: plugin`. The clusters moved one per PR, least important first (scanopy,
firefly, n8n, synapse, authelia), and the Renovate hold on the operator chart is lifted.

## Reasons

- Same paths keep a single recovery window per database across the switch. After the
  migration each `ObjectStore` reports a `firstRecoverabilityPoint` of 2026-11-10, a
  week before the switch, and retention keeps pruning old and new backups together.
- Restores were tested, not assumed: two scratch clusters bootstrapped from
  `ObjectStore/postgres-scanopy`, one with `targetTime` before the switch (base backup
  and WAL written in-tree) and one to the latest point (backup written by the plugin).
  Both came up with the same row counts as the live database and were then deleted.
- The plugin is the upstream path; the in-tree code is gone in the next operator minor.

## Trade-offs

- One more component in the backup path. If the plugin Deployment is down, WAL stays in
  `pg_wal` until it returns; the existing `PostgresWALArchivingBacklog*` alerts cover a
  long outage.
- Plugin and operator versions are now coupled. Both stay in Renovate's PR-only stateful
  group; check the plugin's compatibility notes before either bump.
- Every Cluster change that adds or removes the plugin restarts its single instance. With
  CNPG's smart shutdown waiting up to 180s for clients, that was about 3.5 minutes of
  database downtime per cluster, and n8n did not reconnect on its own (its pod needed a
  restart).

## Consequences

- The sidecar is an init container with `restartPolicy: Always`. Kyverno's
  `require-resource-limits` is enforced in `database` and checks init containers, so
  the sidecar needs both cpu and memory limits (`instanceSidecarConfiguration` in the
  `ObjectStore`). The first migration lacked the cpu limit, and the scanopy pod was
  rejected at admission until it was added (#1226).
- `ObjectStore`s sync in wave `-1`. The plugin's pre-reconcile hook stops without
  requeue on a Cluster whose `ObjectStore` does not exist yet, which stalled the first
  rollout until a manual reconcile.
- Backup age moves to `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`.
  `CNPGBackupTooOld` covers every cluster (it replaced the authelia-only alert on
  `cnpg_collector_last_available_backup_timestamp`); a freshly started sidecar reports
  0, which `CNPGBackupCatalogUnknown` handles. firefly got the PodMonitor it never had.
- Restores use `bootstrap.recovery` with an `externalClusters[].plugin` source; see
  `kubernetes/system/postgres/README.md` and `DISASTER-RECOVERY.md` section 5a.
- The operator chart can move to 0.30 / operator 1.31 through the normal Renovate PR.
