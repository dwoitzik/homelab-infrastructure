# Gotify

Self-hosted push-notification server (`gotify.woitzik.dev`).

## Storage

Single `nfs-client` PVC — SQLite database of registered apps/clients and message
history.

## How to restore

Standard PVC swap-restore: scale to 0, mount the PVC via a throwaway pod, copy
preserved data in, scale back up.
