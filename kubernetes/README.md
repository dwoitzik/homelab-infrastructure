# K3s GitOps Cluster

This is the Kubernetes layer of the homelab — 3-node k3s, all control-plane with embedded
etcd, fronted by Traefik and managed by ArgoCD.

## Stack

| Component | What | Notes |
|---|---|---|
| Distribution | k3s | All 3 nodes run control-plane + etcd, no single primary |
| GitOps | ArgoCD | ApplicationSet auto-deploys everything under `apps/` |
| Ingress | Traefik | TLS termination, OIDC via Authelia ForwardAuth |
| Storage | NFS (`nfs-client` StorageClass) | Backed by `ct-srv-nfs-01`. Used to be Longhorn — migrated off it, see ROADMAP.md |
| Certificates | cert-manager + Cloudflare DNS-01 | One wildcard cert (`*.woitzik.dev`), bound to Traefik's `TLSStore` |
| Load balancer | MetalLB | VIP `10.0.20.200` |
| Identity | Authelia | SSO + OIDC for everything that supports it |
| Secrets | HashiCorp Vault + External Secrets Operator | See `docs/secrets-inventory.md` |

## Layout

```
├── system/      # Manually-applied infra (Traefik, ArgoCD itself, monitoring, Vault, etc.)
└── apps/        # ArgoCD-managed workloads — drop a folder in here, it deploys itself
```

`system/` isn't watched by the ApplicationSet, so anything there needs a manual
`kubectl apply` the first time. `apps/` is fully GitOps — push and ArgoCD picks it up.

## Adding a new app

1. New directory under `apps/`, with a Deployment + Service (+ PVC if it needs one).
2. Add an IngressRoute to `kubernetes/system/apps-ingressroute.yml` and apply it manually — that file isn't ArgoCD-managed.
3. Push to `main`. ArgoCD detects the new directory and deploys it.

Protecting a route with Authelia is just an annotation:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: kube-system-authelia@kubernetescrd
```
