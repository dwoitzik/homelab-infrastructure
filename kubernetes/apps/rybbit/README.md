# Rybbit (in-cluster routing)

Rybbit itself runs on `ct-srv-rybbit-01` (10.0.20.205), not in k3s -- see
`ansible/roles/rybbit/README.md` for the actual stack (Caddy, Postgres,
ClickHouse, Redis, backend, client) and its own gotchas.

This directory holds only the piece k3s needs: `external-rybbit`, a headless
Service+Endpoints pointing at that LXC, so Traefik's `rybbit-final`
IngressRoute (`kubernetes/system/apps-ingressroute.yml`) can route
`analytics.woitzik.dev` to it -- same external-LXC pattern as jellyfin/wazuh.

## Access paths

Both paths end at Traefik's `rybbit-final` IngressRoute
(`kubernetes/system/apps-ingressroute.yml`), see
`docs/decisions/ADR-074-rybbit-public-path-through-traefik.md`:

- **Public** (real site visitors): Cloudflare Tunnel -> Traefik
  (`terraform/stacks/cloudflare/main.tf`, ADR-033's public allowlist).
- **LAN/Tailscale**: `*.woitzik.dev` AdGuard wildcard -> Traefik.

`rybbit-final` has two routes. The tracker endpoints the woitzik.dev script
calls (`/api/script.js`, `/api/track`, `/api/identify`, `/api/site/...`,
`/api/session-replay/record/...`, `/api/replay.js`, `/api/metrics.js`,
`/api/health`) get CrowdSec + `rybbit-ratelimit` (`middleware.yml`) and no
Authelia. Everything else, including the dashboard, `/api/auth/*` and
`/api/admin/*`, gets CrowdSec + Authelia. Since Authelia's portal is not
public, the dashboard is reachable from LAN/Tailscale only.

If a Rybbit update makes the script call a new path, that path hits the
Authelia route and fails closed: add it to the tracker route's match.

## Egress

Public traffic reaches the LXC through Traefik (ADR-074), so cloudflared has
no direct egress rule to it. `allow-egress-nextcloud-authelia` lives in
`kubernetes/apps/network-policies-egress.yml`, a loose file tracked by the
`apps-loose-manifests` Application, not the per-directory ApplicationSet --
apply it manually (`kubectl apply -f`) if a change here doesn't seem to take
effect after a merge.
