# Traefik

Ingress controller for the whole cluster — every hostname in
`docs/URL-INVENTORY.md` eventually routes through this. Deployed via the official Helm
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

## ServersTransport

`kubernetes/system/infrastructure/transport.yml` — `insecure-transport` (two copies,
one per namespace that needs it: `apps` and `kube-system`) for routing to
self-signed-cert backends (Proxmox, PBS, Wazuh) without failing TLS verification.

## Dependencies

MetalLB (LoadBalancer IP), cert-manager (the wildcard cert). Everything else depends on
this.
