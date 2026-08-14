# Keel

Container image auto-update watcher. Installed but not the primary update mechanism —
Renovate (PR-based, with a tiered auto-merge policy, see `kubernetes/apps/renovate/`)
handles routine dependency updates; Keel exists as a secondary/faster-response option,
not actively relied on.

## Storage

None — stateless, watches running Deployments' image tags directly.
