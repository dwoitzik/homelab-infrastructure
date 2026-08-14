# redis

Single-instance Redis StatefulSet, used by Authelia for session storage. Not a
Helm-chart deployment — plain hand-written manifests, since this is a single small
instance with no need for the Bitnami/operator machinery.

## How to restore

Ephemeral by design — session data, not something backed up or restored. A fresh
StatefulSet just means every user re-authenticates once.

## Dependencies

None. Authelia depends on this.
