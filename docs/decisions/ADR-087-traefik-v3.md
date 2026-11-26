# ADR-087: Move Traefik from v2.11 to v3 in two chart steps

**Date:** 2026-11-26
**Status:** Accepted, applied

## Context

Traefik ran v2.11.2 from Helm chart 27.0.2. v2 is out of support, and every chart
since 28 ships v3. Traefik is the only ingress: Authelia forward auth, the CrowdSec
bouncer plugin (ADR-079), the Cloudflare tunnel upstream, the DMZ Loki push
entrypoint and the tailnet DNAT to the `websecure` NodePort all depend on it.

The v2 to v3 migration guide and the v3 minor-version notes up to v3.7.20 were checked
against what this cluster actually configures:

- **Rule syntax.** All 45 IngressRoutes use `Host`, `Path` and single-argument
  `PathPrefix` joined with `&&`/`||`. No `HostRegexp`, `Headers`, `HostHeader`,
  multi-argument matchers or path placeholders, so the v3 syntax parses every rule
  unchanged and `core.defaultRuleSyntax: v2` is not needed.
- **Middlewares.** `forwardAuth` (Authelia), `rateLimit` by `Cf-Connecting-Ip`,
  `headers` (custom request/response headers only), `redirectRegex` and the CrowdSec
  plugin. None of the removed options (`ipWhiteList`, `sslRedirect`, `featurePolicy`,
  `stripPrefix.forceSlash`, `tls.caOptional`) is used.
- **API group.** No object exists in `traefik.containo.us`; every resource is
  `traefik.io/v1alpha1`. Chart 28 no longer ships the `containo.us` CRDs. Argo CD had
  never tracked them, so it did not prune them; the nine empty CRDs were deleted by
  hand after step 1.
- **Endpoints.** From v3.1 Traefik reads EndpointSlices instead of v1 Endpoints. The
  selectorless Services for hosts outside the cluster (Jellyfin, the *arr stack, PVE,
  PBS, router, Rybbit, AdGuard, Headscale on the RPi) already have mirrored
  EndpointSlices from the `endpointslicemirroring-controller` with `ready: true`, so
  they keep resolving.
- **CrowdSec plugin.** v1.6.0 is developed and tested against Traefik v3 (its own
  compose file runs `traefik:v3.0.0`); the local-plugin loading path
  (`experimental.localPlugins`, `/plugins-local/src/<module>`) is unchanged in v3.
- **Path handling.** v3.6.4 to v3.6.6 rejected encoded `/`, `\`, `;`, `%`, `?`, `#`
  in paths by default; v3.6.7+ allows them again, so the target version keeps v2
  behaviour. Path sanitizing (v3.3.6) and normalization (v3.4.1) apply; no route
  here depends on unsanitized paths.
- **Other behaviour changes.** No more `Content-Type` sniffing for responses without
  one; `trustForwardHeader` on ForwardAuth deprecated but still honoured; internal
  routers (`ping@internal`) no longer in access logs. No Prometheus rule or dashboard
  in this repo uses a Traefik metric that v3 renamed.

## Decision

Two PRs, each verified live before the next:

1. **Chart 28.3.0 (Traefik v3.0.2).** Only the chart version changes; chart 28 still
   accepts the chart 27 values. This isolates the v2 to v3 engine change.
2. **Chart 42.4.3 (Traefik v3.7.20).** Values rewritten to the current schema:
   `logs` becomes `log`/`accessLog` (header `defaultMode: drop` and the redactions
   kept explicit), `ports.web.redirectTo` becomes
   `ports.web.http.redirections.entryPoint` to `:443`, entrypoint TLS moves under
   `http.tls`, `lokipush.expose` becomes `{default: false}`, and `ports.traefik.port`
   is pinned to 9000 because chart 33 moved the default to 8080 and the startup probe,
   the `traefik-api` Service, the kube-system network policy and the Homepage widget
   all use 9000. Chart 43 (Traefik v3.8.0) was two days old and is left for Renovate.

Rollback for either step: revert the PR, `argocd app sync traefik` (or let auto-sync
pick it up), confirm both pods Ready. The `traefik` LoadBalancer Service is updated in
place, so the MetalLB address 10.0.20.200 and the NodePorts (30241/30777) the tailnet
DNAT depends on do not change.

## Consequences

- The `containo.us` CRDs are gone; `kubectl get ingressroute` is no longer ambiguous.
- The v3 rule syntax is now the only syntax in use, which is what v4 will require.

## Result

- Step 1 (#1320): v3.0.2 rolled out with both pods Ready through the startup probe, 52
  of 52 routers and every middleware enabled, the ingress smoke test (Authelia
  redirects, direct hosts, HTTP to HTTPS, wildcard certificate, public hosts through
  the tunnel) unchanged, and a test IP banned on the CrowdSec LAPIs answered 403.
- Step 2: same checks against v3.7.20, recorded in its PR.
