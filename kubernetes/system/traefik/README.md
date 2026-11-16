# Traefik

Ingress controller for the whole cluster: every in-cluster hostname eventually routes
through this. Deployed via the official Helm
chart (`application.yml`), fronted by MetalLB for its LoadBalancer IP.

## Routing

IngressRoutes live in `kubernetes/system/apps-ingressroute.yml` and
`other-ingressroute.yml` — deliberately **not** ArgoCD-managed (applied manually), so
routing changes don't get tangled up with the selfHeal-vs-live-patch issues every other
ArgoCD-tracked resource has. Traefik's Kubernetes CRD provider resolves Service
backends through the legacy v1 `Endpoints` API ("subsets"), not `EndpointSlice` —
confirmed live (a bare EndpointSlice silently 404s with "subset not found"). Every
headless external-service pattern in this repo (Jellyfin, Atlantis, PVE/PBS, Wazuh,
router, AdGuard) relies on this.

Two IngressRoute CRD group versions coexist in this cluster
(`ingressroutes.traefik.containo.us` and `ingressroutes.traefik.io`) — `kubectl get
ingressroute` (bare name) is ambiguous between them and silently returns nothing.
Always use the fully-qualified `ingressroute.traefik.io`.

## TLS

Single wildcard certificate (`kubernetes/system/certificates/wildcard-woitzik-dev.yml`)
covers every hostname — no per-service certificate management as new apps are added.

## Middlewares

`crowdsec-bouncer` (CrowdSec's Traefik plugin, blocks known-bad IPs at the edge),
`authelia` (forward-auth SSO), `websockets`, plus a few service-specific ones
(`immich-ratelimit`, `loki-to-grafana-redirect`). Defined in
`kubernetes/apps/crowdsec/middleware.yml` and inline in the IngressRoute files.

## CrowdSec plugin (local, ADR-079)

The CrowdSec bouncer plugin is loaded with `experimental.localPlugins`, not downloaded
from plugins.traefik.io. The `plugin-source` initContainer copies the plugin tree from
`ghcr.io/dwoitzik/traefik-crowdsec-plugin` (built from
`images/traefik-crowdsec-plugin/Dockerfile` by
`.github/workflows/traefik-plugin-image.yml`) into an emptyDir mounted at
`/plugins-local`.

A `startupProbe` asks Traefik's internal API for
`apps-crowdsec-bouncer@kubernetescrd` and passes only on `"status":"enabled"`. A pod
whose plugin did not load never turns Ready, so it never serves 404s for the
CrowdSec-protected routes. If you rename that Middleware, change the probe URL in the
same PR, or new Traefik pods will not start.

Check a pod by hand:

```bash
kubectl -n kube-system exec deploy/traefik -- \
  wget -qO- http://127.0.0.1:9000/api/http/middlewares/apps-crowdsec-bouncer@kubernetescrd
kubectl -n kube-system logs deploy/traefik | grep -i 'plugins are disabled'   # expect nothing
```

### Bumping the plugin version

1. Update `PLUGIN_VERSION` and `PLUGIN_COMMIT` in
   `images/traefik-crowdsec-plugin/Dockerfile` (Renovate opens this PR itself). Read the
   plugin's release notes for Middleware option changes
   (`kubernetes/apps/crowdsec/middleware.yml`).
2. Merge; the workflow pushes `ghcr.io/dwoitzik/traefik-crowdsec-plugin:<version>` and
   prints the digest in its run summary.
3. Update the `plugin-source` image tag and digest in `application.yml` (Renovate's
   kubernetes manager picks up the new tag). Merge, then confirm both pods are Ready
   and the log grep above is empty.

## ServersTransport

`kubernetes/system/infrastructure/transport.yml` — `insecure-transport` (two copies,
one per namespace that needs it: `apps` and `kube-system`) for routing to
self-signed-cert backends (Proxmox, PBS, Wazuh) without failing TLS verification.

## Dependencies

MetalLB (LoadBalancer IP), cert-manager (the wildcard cert), GHCR for the plugin
image on nodes that have not cached it yet. Everything else depends on this.
