# n8n

Workflow automation. Not in the brief's original Tier-1 dataset list, preserved anyway
per the recovery's own "preserve first, ask questions later" principle for anything that
might hold personal data.

## Storage

Postgres via CloudNativePG — `kubernetes/system/postgres/cluster-n8n.yml`, **not**
`kubernetes/apps/n8n/`. This lives under `kubernetes/system/postgres/` because it's a
shared-pattern location alongside Authelia's and Synapse's CNPG clusters, outside the
`homelab-apps` ApplicationSet's `kubernetes/apps/*` glob — it has to be applied
explicitly, ArgoCD's app-of-apps auto-discovery does not pick it up on its own. The n8n
app itself (`kubernetes/apps/n8n/`) is a plain Deployment with no PVC of its own; all
persistent state is in the database.

## How to restore

Standard CNPG hibernate → swap PVC contents → un-hibernate. Verified low usage in the
pre-disaster data (`workflow_entity`: 0 rows) — this is the real, correct state, not a
restore failure; don't mistake an empty-looking table for lost data without checking
against what was actually there before.

## Known gotchas

- If `postgres-n8n` shows `stop: true` in its spec, that's a leftover from an I/O
  stabilization pause during an earlier recovery phase — remove it, don't assume it's
  intentional.
- Continuous WAL archiving to Garage needs the `cnpg-garage-backup` Secret
  (`kubernetes/system/postgres/external-secret.yml`) and `cnpg-backup-config`
  (`backup-config.yml`) — both live in the same directory as the cluster manifest but are
  separate files that also need applying explicitly.
