# ADR-009: Vault auto-unseal via polling sidecar

**Date:** 2026-06-18
**Status:** Accepted

## Context

HashiCorp Vault is deployed single-node (`server.ha.enabled: false`, raft storage,
`node_id: vault-0`) as the secrets root for External Secrets Operator and several apps'
credentials. Vault seals itself on every restart (pod reschedule, node reboot, or cluster
rebuild) and a sealed Vault refuses all reads — Shamir's Secret Sharing requires unseal
keys to be supplied again after every seal event.

Vault Enterprise offers auto-unseal via an external KMS (AWS KMS, Azure Key Vault, GCP
KMS, or HashiCorp's own Transit engine). None of those are available or appropriate
here: this is Vault OSS, there's no cloud KMS in the homelab's trust boundary, and running
a second Vault instance purely to auto-unseal the first is circular.

## Decision

Run a small polling `Deployment` (`vault-unseal`, in `kubernetes/system/vault/unseal.yml`)
that checks `vault status` every 5 seconds and, whenever Vault reports sealed, submits the
two unseal key shares pulled from a Kubernetes Secret (`vault-unseal-keys`) via
`vault operator unseal`.

## Reasons

This is the pragmatic OSS equivalent of auto-unseal without a KMS dependency: the unseal
keys exist as a Kubernetes Secret (created once, out-of-band, from Ansible Vault-held key
material) and a sidecar applies them automatically whenever sealing is detected. It keeps
the threshold-secret-sharing security property (no single key unseals Vault — multiple
shares from the Secret are required) while removing the manual "someone has to run
`vault operator unseal` by hand after every reboot" step, which is not viable for a
homelab that reboots unattended.

The poll interval was originally 30 seconds; it was reduced to 5 seconds 2026-06-23
(REL-007) specifically to shrink the window during which dependent pods see Vault as
sealed and their ExternalSecrets fail to sync.

## Trade-offs

- The unseal keys live in a Kubernetes Secret, readable by anything with cluster-admin
  or Secret-read access to the `vault` namespace — this collapses Vault's security
  boundary down to "whoever can read Kubernetes Secrets in this namespace," which is a
  materially weaker model than a real external KMS. Acceptable here because the alternative
  (no auto-unseal) is an unrecoverable cluster on every reboot, and the cluster's overall
  trust boundary already assumes a single trusted admin
- There is still a seal window (now ~5–10s) on every restart during which Vault is sealed
  and any ExternalSecret depending on it cannot sync — mitigated, not eliminated, by faster
  polling and `wait-for-vault-secret` initContainers on the two apps observed crash-looping
  (Authelia, `postgres-paperless`)
- Vault's own raft storage (`data-vault-0`) sits on the `nfs-client` StorageClass, the same
  storage layer that caused SQLite corruption elsewhere in the cluster (GIT-006). Raft uses
  BoltDB, which has similar though less severe (single-writer, not WAL/shared-mmap) locking
  needs — no corruption seen yet, but this is flagged separately (REL-009) as deserving its
  own dedicated migration given Vault's blast radius as the secrets root

## Consequences

`vault-unseal` is deployed as its own ArgoCD Application
(`kubernetes/system/vault/manifests-application.yml`) separate from the Vault Helm chart,
so it survives Helm upgrades/redeploys of Vault itself. Any new app that reads secrets via
ExternalSecrets backed by Vault should assume a multi-second window after any
restart/reboot during which Vault may be sealed, and should tolerate it (e.g. via an
initContainer wait pattern) rather than crash-looping.
