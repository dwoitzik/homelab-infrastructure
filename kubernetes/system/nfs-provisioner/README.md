# nfs-subdir-external-provisioner

Backs the `nfs-client` StorageClass — dynamic PV provisioning against the NFS server
LXC (`ct-srv-nfs-01`, `10.0.20.100:/nfs-data/k8s-general`). Default StorageClass for
bulk/shared data without its own locking-sensitive embedded database.

## Not safe for embedded databases

NFS's locking/WAL model is incompatible with how SQLite/BoltDB-class engines manage
concurrent access — Garage's metadata store corrupted this way in practice (see
`docs/k3s-architecture.md`). Every app found to be SQLite-backed was migrated to
`local-path` instead. New apps with an embedded DB should default to `local-path`, not
this.

## Dependencies

The NFS server LXC being up and the export reachable.
