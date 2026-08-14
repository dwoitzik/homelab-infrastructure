# ArgoCD

GitOps engine for this whole cluster. Watches this repo (`main` branch) and reconciles
live cluster state to match what's committed — a merge to `main` is a deploy.

## Structure

- `system-app-bootstrap.yml` — the "app of apps" root: the one Application this repo's
  operator applies manually once, everything else is bootstrapped from here.
- `apps-applicationset.yaml` — the `homelab-apps` ApplicationSet, watches
  `kubernetes/apps/*` and creates one Application per subdirectory automatically. New
  app directories don't need a new Application written by hand.
- System components (`kubernetes/system/*`) are standalone Applications, applied
  individually — not swept up by the ApplicationSet, since they need to bootstrap before
  ArgoCD's own dependencies (Vault, ExternalSecrets) are ready.
- `argocd-cm.yml` / `argocd-cmd-params-cm.yml` / `argocd-rbac-cm.yml` — server config,
  including OIDC login via Authelia and RBAC policy.
- `argocd-notifications-cm.yml` + `notifications-external-secret.yml` — Discord
  notifications on sync/health events.
- `network-policies.yml` — default-deny plus explicit allows for the `argocd`
  namespace.

## selfHeal — the recurring gotcha

Every Application here runs with `syncPolicy.automated.selfHeal: true`. A live
`kubectl` patch to any ArgoCD-tracked resource gets reverted, usually within seconds —
confirmed repeatedly during this recovery. The only durable fix for a tracked resource
is committing the change and letting ArgoCD sync it, not a live patch. Resources that
are deliberately *not* ArgoCD-managed (most IngressRoutes, headless external
Service/Endpoints pairs) are the escape hatch for things that need to be edited outside
this flow.

## How to restore

No persistent state of its own beyond what's declared here — a fresh ArgoCD install
pointed at this repo's `main` branch reconciles the entire cluster from scratch. This is
exactly what happened during the 2026-08-13 disaster recovery: ArgoCD was one of the
first things reinstalled, before any other workload.

## Dependencies

None to bootstrap (first thing installed after core cluster components). Everything
else depends on it.
