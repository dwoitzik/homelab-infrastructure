# MySpeed

Internet speed-test history tracker (`speed.woitzik.dev`).

## Storage

Single `nfs-client` PVC — historical speed-test results.

## How to restore

Standard PVC swap-restore: scale to 0, mount the PVC via a throwaway pod, copy
preserved data in, scale back up.
