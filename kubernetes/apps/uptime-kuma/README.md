# Uptime Kuma

Uptime/status monitoring.

## Storage

Single `local-path` PVC — SQLite database of monitors, check history, status pages.

## How to restore

Standard `local-path` swap-restore: scale to 0, mount the PVC via a throwaway pod,
copy preserved data in, scale back up.

## Known gotchas

- **No monitors are actually configured** — this is a real, pre-existing gap (not
  something the 2026-08-13 recovery caused), confirmed during that recovery's own data
  verification (0 monitors, matching the pre-disaster state exactly). Uptime Kuma is
  deployed and healthy but not actually watching anything yet.
