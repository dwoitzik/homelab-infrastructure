# Gitea

Self-hosted git hosting. Deployed fresh/empty by design — not a gap.

## Why there's no data to restore

Investigated as a genuine Tier-1 concern during the 2026-08-13 disaster recovery: the
local-path PVC's `gitea-data` was an empty skeleton (config template only, no `gitea.db`,
no repositories) with a stale mtime predating the disaster by weeks. Checked every
recovery avenue before concluding anything — the preserved pre-disaster VM disk, the NFS
server, and the Velero/Garage kopia backup layer all independently showed the exact same
empty state, going back to at least early August. This predates the disaster entirely;
it isn't something the rebuild lost.

**Operator-confirmed (2026-08-13): Gitea never had real data worth preserving.** Deployed
fresh as a normal rebuild, not a data-loss recovery.

## Storage

Single PVC (`local-path`) holding the SQLite database, repository data, and SSH host
keys once actually used.
