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

## Known gap — Vault does NOT have a reliable generic backup

**Velero's generic kopia filesystem backup does not reliably protect Vault.** A raw
filesystem-level snapshot of Vault's raft/bolt database files taken *while Vault is live
and actively in use* is not guaranteed crash-consistent — proven live during this
recovery's own backup/restore verification: a Velero-restored copy had the right files at
the right sizes, but Vault itself reported `Initialized: false` against it. The live
StatefulSet is patched with `backup.velero.io/backup-volumes-excludes: data` to stop the
daily schedule from attempting this unreliable path at all, rather than silently
producing backups that look successful but can't actually restore.

**What's still needed, not yet built:** a real backup mechanism using Vault's own
`vault operator raft snapshot save` (an application-level, consistent snapshot), written
somewhere Velero/Garage can pick it up on a schedule. Until this exists, Vault's *current
live data* is safe (recoverable via the unseal-key procedure above, same as any other
`local-path` service), but there is no tested, working path to recover from a scenario
where the live cluster is lost *and* the old cluster's datastore is also gone.
