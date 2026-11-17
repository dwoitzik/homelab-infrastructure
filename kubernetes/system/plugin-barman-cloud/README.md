# plugin-barman-cloud

The [Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/) for
CloudNativePG (CNPG-I). It replaces the operator's in-tree
`spec.backup.barmanObjectStore`, which CNPG deprecated in 1.26 and is removing. Every
`Cluster` in `kubernetes/system/postgres/` archives WAL and takes base backups through
it, to Garage at `s3://cnpg-backups/<name>`.

Deployed from the official Helm chart (`cloudnative-pg/charts`, `plugin-barman-cloud`)
into `cnpg-system`, next to the operator. The plugin has to live in the operator's
namespace: the operator finds it through the `barman-cloud` Service there (label
`cnpg.io/pluginName`) and talks to it over mutual TLS on port 9090.

## Pieces

- **Plugin Deployment** (`cnpg-system/plugin-barman-cloud`): serves the CNPG-I gRPC
  API to the operator and reconciles `ObjectStore` resources.
- **`ObjectStore` CRD** (`barmancloud.cnpg.io/v1`): one per cluster, in
  `kubernetes/system/postgres/object-stores.yml`. Holds the S3 destination,
  credentials, compression and retention policy that used to sit in each `Cluster`'s
  `spec.backup`.
- **Sidecar** (`plugin-barman-cloud`, injected into every instance pod that lists the
  plugin under `spec.plugins`): runs `barman-cloud-wal-archive` and
  `barman-cloud-backup` from inside the pod.
- **TLS**: a self-signed cert-manager `Issuer` plus server and client `Certificate`s,
  all created by the chart. Needs cert-manager.

## Network

`cnpg-system` is default-deny for ingress and egress. The operator reaches the plugin
through `allow-barman-cloud-plugin-from-operator`
(`kubernetes/system/monitoring/netpol-ingress-cnpg-system.yml`); egress inside the
namespace and to the apiserver is already allowed. The sidecar in each instance pod
uses the `database` namespace's existing egress to Garage (`:3900`) and the apiserver.

## Upgrades

The plugin and the operator version are coupled: plugin 0.16 needs CNPG 1.30 or newer.
Check the plugin's release notes against the running operator before bumping either.
Renovate keeps both in the PR-only stateful group. The Deployment uses the `Recreate`
strategy, so an upgrade pauses WAL archiving for the length of the pod restart;
Postgres keeps the segments in `pg_wal` and the sidecar ships them afterwards.

## How to restore

The plugin holds no data. Re-sync this Application, then restore a database as
described in `kubernetes/system/postgres/README.md`.

## Dependencies

CloudNativePG operator (1.30+), cert-manager, Garage.
