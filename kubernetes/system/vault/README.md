# Vault

HashiCorp Vault, standalone mode, raft storage on `local-path`. Backs every
ExternalSecret in the cluster — this is the actual root of trust for the whole
homelab's secrets, not just another app.

## Storage

`local-path` PVC holding `vault.db` (BoltDB) and `raft/` (the raft log/snapshots).

## How to restore — the circular-dependency problem

A fresh Vault instance can't unseal itself; unsealing needs the unseal keys, which are
themselves stored as a Kubernetes Secret *inside the very cluster whose data was just
lost*. Recovering from a full cluster rebuild means recovering the unseal keys from the
**old, pre-disaster cluster's own preserved datastore** — a genuine chicken-and-egg
situation, not solvable by just restoring Vault's own PVC.

The procedure that worked (2026-08-13): spin up a disposable, network-isolated temporary
k3s server instance pointed at the *old* cluster's preserved SQLite/kine datastore, use
it read-only to extract the `vault-unseal-keys` Secret, then destroy the temp instance.
Unseal key material was never displayed in any command output or log at any point in this
process — extracted straight to files, used, then the files removed. This is a reusable
technique for any future scenario where a k3s node's SQLite datastore survives but the
live cluster built from it doesn't.

Once unsealed, Vault's own data (the raft log) restores the same way as any other
`local-path` PVC — copy the preserved files back, restart.

## Backup: raft snapshots

A raw filesystem copy of Vault's raft/bolt files taken while Vault runs is not
crash-consistent: a Velero-restored copy once came up as `Initialized: false`. So
vault-0's `data` volume is excluded from Velero (`server.annotations` in
`application.yml`), and `snapshot.yml` runs `vault operator raft snapshot save` as a
Velero pre-backup hook instead. The snapshot lands in the `vault-snapshots` PVC
(`/snapshots/vault.snap`), which the daily local and offsite backups copy. It is
encrypted with the barrier key, so restoring it needs the unseal keys.

The hook authenticates with a periodic token (policy `raft-snapshot`, read on
`sys/storage/raft/snapshot`) stored at `secret/vault-snapshot` property `token`;
each run renews it. One-time setup with an admin token:

```sh
vault policy write raft-snapshot - <<'POLICY'
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
POLICY
vault kv put secret/vault-snapshot token="$(vault token create -orphan -policy=raft-snapshot \
  -period=768h -display-name=vault-snapshot -field=token)"
```

Restore onto a fresh, initialized and unsealed Vault:

```sh
kubectl -n vault cp vault-snapshot-<pod>:/snapshots/vault.snap ./vault.snap
vault operator raft snapshot restore -force vault.snap   # then unseal with the original keys
```
