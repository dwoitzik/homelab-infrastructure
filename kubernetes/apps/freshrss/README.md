# FreshRSS

Self-hosted RSS reader (`rss.woitzik.dev`).

## Storage

Single `nfs-client` PVC — feed subscriptions, read state, and its own SQLite/config
data all live here.

## How to restore

Standard PVC swap-restore: scale to 0, mount the PVC via a throwaway pod, copy
preserved data in, scale back up.
