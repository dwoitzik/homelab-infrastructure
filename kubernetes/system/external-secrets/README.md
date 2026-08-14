# External Secrets Operator (ESO)

Syncs secrets from Vault into native Kubernetes Secrets — the bridge every
`ExternalSecret` resource in this repo depends on (Vault is the actual source of
truth; the resulting k8s Secret is a generated artifact, not hand-edited).

## Contents

- `application.yml` — the ESO Helm chart.
- `cluster-secret-store.yml` — the `ClusterSecretStore` pointing at Vault's KV v2
  engine, authenticated via a Kubernetes auth-method service account (not a static
  Vault token).

## Sync direction — check before writing to Vault

ExternalSecrets sync Vault → Kubernetes, one-way. Writing a stale/wrong value to Vault
will overwrite a working live k8s Secret on the next sync interval — confirmed as a
real risk this recovery flagged explicitly (Q6/Q7 in `phase1/QUESTIONS.md`: several
Vault-stored credentials had drifted from what was actually live, and the fix was
live-Secret-first, Vault-write-second, specifically to avoid this failure mode).

## How to restore

Needs Vault unsealed and reachable first (see `kubernetes/system/vault/README.md`).
Once the ClusterSecretStore can authenticate, every ExternalSecret across the cluster
re-syncs automatically.

## Dependencies

Vault.
