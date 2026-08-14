# Mealie

Recipe manager.

## Storage

Single `local-path` PVC — SQLite database of recipes/meal plans/shopping lists.

## How to restore

Standard `local-path` swap-restore: scale to 0, mount the PVC via a throwaway pod,
copy preserved data in, scale back up. Restored and verified during the 2026-08-13
recovery — `sqlite3 ... "PRAGMA integrity_check;"` = ok, 1 real user, matching the
pre-disaster state exactly.
