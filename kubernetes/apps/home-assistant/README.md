# Home Assistant

Smart-home hub.

## Storage

Single `local-path` PVC — `local-path` rather than `nfs-client` because Home Assistant
writes its config/state frequently and benefits from node-local latency; it's a
single-writer workload so the usual `nfs-client` sharing advantage doesn't apply here.

## How to restore

File-level copy: scale to 0, mount the PVC via a throwaway pod, copy the preserved
`/config` directory in, scale back up. Verified 2026-08-13 via a straight file-count/
content comparison against the pre-disaster copy, not just "pod is Running."
