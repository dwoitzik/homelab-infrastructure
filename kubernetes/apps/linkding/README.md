# Linkding

Self-hosted bookmark manager (`links.woitzik.dev`).

## Storage

Single `nfs-client` PVC — SQLite database of bookmarks/tags.

## How to restore

Standard PVC swap-restore: scale to 0, mount the PVC via a throwaway pod, copy
preserved data in, scale back up.
