# argocd-install

ArgoCD's own workloads (ADR-078): the upstream `install.yaml` at the running version,
minus the objects other sources own (config ConfigMaps, `argocd-secret`, the
notifications Secret, UI-edited ConfigMaps, CRDs), plus resource requests and memory
limits. Synced by the `argocd-install` Application with `prune: false`.

## Upgrade

1. Apply the new release's CRDs by hand:
   `kubectl apply --server-side --force-conflicts -k https://github.com/argoproj/argo-cd/manifests/crds?ref=<version>`
   (`--force-conflicts`: the live CRDs carry fields owned by an earlier client-side apply).
2. Change the version in the `resources` URL of `kustomization.yaml` and merge.

## Restore

If ArgoCD cannot sync itself, apply this directory directly from a checkout:
`kubectl apply --server-side --force-conflicts -k kubernetes/system/argocd-install`.

## Dependencies

Egress from the repo-server to raw.githubusercontent.com (allowed by
`allow-egress-chart-repos`).
