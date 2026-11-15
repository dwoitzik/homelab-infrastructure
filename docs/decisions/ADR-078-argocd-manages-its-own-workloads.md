# ADR-078: ArgoCD manages its own workloads, without prune

**Date:** 2026-11-15
**Status:** Accepted, applied

## Context

ArgoCD's configuration (`argocd-cm`, RBAC, notifications, ingress, network policies) has
been GitOps-managed through `argocd-manifests` for a long time, but its workloads were
not: the seven Deployments/StatefulSet came from a one-off `kubectl apply` of the upstream
`install.yaml`, and nothing in Git described them. They ran without any resource
requests. The application controller alone uses ~850Mi, so the scheduler could not see
roughly 1.2Gi of real usage, which matters on a three-node cluster that only just fits
its memory requests after losing a worker (`KubeMemoryOvercommitWorkerLoss`).

Patching the live objects by hand would add exactly the kind of undeclared drift this
repo exists to avoid, and the next reinstall would silently drop it.

A comparison of the live objects with `install.yaml` v3.5.1 (the running version) showed
no differences apart from defaulted fields, so the upstream manifest is an accurate
description of what runs today.

## Decision

1. `kubernetes/system/argocd-install/kustomization.yaml` takes the upstream
   `install.yaml` at the running version and:
   - removes the objects another source owns: `argocd-cm`, `argocd-cmd-params-cm`,
     `argocd-rbac-cm`, `argocd-notifications-cm` (argocd-manifests),
     `argocd-notifications-secret` (ExternalSecret), `argocd-secret` (server key and
     admin credentials, never overwritten), the three UI-edited ConfigMaps
     (`argocd-ssh-known-hosts-cm`, `argocd-tls-certs-cm`, `argocd-gpg-keys-cm`) and the
     three CRDs (CRD upgrades stay a deliberate manual step);
   - adds requests and memory limits to every workload.
2. Application `argocd-install` syncs it with `selfHeal: true`, `prune: false`,
   ServerSideApply, and no resources finalizer. A bad commit can change ArgoCD's
   workloads but cannot delete them, and deleting the Application leaves ArgoCD running.
3. An ArgoCD upgrade becomes a one-line change of the version in the resource URL, plus
   the manual CRD apply from the same release.

## Rollback path that does not depend on ArgoCD

If a change leaves ArgoCD unable to sync itself:
`kubectl apply --server-side --force-conflicts -k kubernetes/system/argocd-install`
from a checkout of the last good commit, or the upstream `install.yaml` directly. Both
work with only cluster-admin kubeconfig access.

## Consequences

- Resource changes to ArgoCD go through a PR like everything else.
- The repo-server fetches the upstream manifest from raw.githubusercontent.com on each
  render; that egress is already allowed for Helm chart repositories.
- Renovate does not track the URL; ArgoCD upgrades stay manual, as before.
