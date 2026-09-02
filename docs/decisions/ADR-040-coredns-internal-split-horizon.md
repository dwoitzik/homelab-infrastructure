# ADR-040: Internal split-horizon DNS for service-to-service calls via CoreDNS

## Status

Accepted

## Context

Headscale crashlooped: its OIDC provider init does a startup fetch of
`https://auth.woitzik.dev/.well-known/openid-configuration`. In-cluster, that
hostname resolves to its public A record, Traefik's external LoadBalancer VIP
(`10.0.20.200`), so the request hairpins out to the VIP and back in. That path
proved intermittently unreliable -- repeated `curl` probes from an in-cluster
pod showed the first request succeeding and the next several instantly
returning `connection refused`. Triggered `SLOAvailabilityFastBurn` and
`ExternalProbeFailed` for headscale.woitzik.dev.

Traefik's own ClusterIP (`10.43.26.11`, stable -- see the `traefik` Service in
`kube-system`) doesn't go through the VIP/hairpin path at all; it's plain
in-cluster Service routing via kube-proxy, which doesn't share the VIP's
failure mode. Traefik routes by Host header/SNI, not by which of its own IPs
the request arrived on, so reaching it via ClusterIP instead of the external
VIP changes nothing about which backend serves the request.

## Decision

Any hostname called service-to-service from inside the cluster gets a CoreDNS
override pointing it straight at Traefik's ClusterIP, via the `coredns-custom`
ConfigMap (`kubernetes/system/infrastructure/coredns-custom.yml`) -- k3s's
standard extension point: keys ending `.override` get imported into CoreDNS's
main server block, no CoreDNS image/Corefile fork needed.

Scope stays narrow and additive: only hostnames with a confirmed in-cluster
caller get an entry (currently just `auth.woitzik.dev`, for headscale's OIDC
check). External clients still resolve the same names publicly and still hit
the real external VIP -- this only changes what pods inside the cluster
resolve to.

## Alternatives considered

- **Point headscale's OIDC issuer at Authelia's ClusterIP directly.** Rejected:
  Authelia's ClusterIP serves plain HTTP (TLS terminates at Traefik); the OIDC
  discovery fetch requires HTTPS with a cert matching the issuer URL, and
  downgrading that for reliability is a real security regression, not a fix.
- **Add a second Traefik replica.** Would reduce single-point-of-failure risk
  generally (worth revisiting separately) but doesn't fix the hairpin path
  itself -- the VIP flakiness reproduced against a single healthy replica in
  testing, so this wouldn't have prevented the incident.
- **hostAliases on the headscale pod only.** Fixes headscale but not the
  general problem -- any other in-cluster caller of a public woitzik.dev
  hostname hits the same hairpin. CoreDNS-level fix covers all pods at once.

## Consequences

- New service-to-service calls across `*.woitzik.dev` need an entry added here
  if the direct-VIP path proves unreliable for them too -- not automatic, has
  to be noticed and added.
- `coredns-custom` is a k3s addon-managed ConfigMap outside ArgoCD's usual
  app boundaries but still deployed via the `infrastructure` Application
  (targets `kube-system`), so it's still GitOps-managed like everything else
  here.
- CoreDNS's `reload` plugin picks up the new file within its default interval
  (30s) once kubelet syncs the ConfigMap to the pod's mounted volume -- no
  CoreDNS restart required, but one was done here to force it immediately
  during incident recovery.
