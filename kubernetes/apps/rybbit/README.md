# Rybbit (in-cluster routing)

Rybbit itself runs on `ct-srv-rybbit-01` (10.0.20.205), not in k3s -- see
`ansible/roles/rybbit/README.md` for the actual stack (Caddy, Postgres,
ClickHouse, Redis, backend, client) and its own gotchas.

This directory holds only the piece k3s needs: `external-rybbit`, a headless
Service+Endpoints pointing at that LXC, so Traefik's `rybbit-final`
IngressRoute (`kubernetes/system/apps-ingressroute.yml`) can route
`analytics.woitzik.dev` to it -- same external-LXC pattern as jellyfin/wazuh.

## Access paths

- **Public** (real site visitors): Cloudflare Tunnel routes straight to the
  LXC's raw IP, bypassing Traefik/this Service entirely
  (`terraform/stacks/cloudflare/main.tf`, ADR-033's public allowlist).
- **LAN/Tailscale**: `*.woitzik.dev` AdGuard wildcard -> Traefik -> this
  Service. Gated by Authelia (`kubernetes/apps/authelia/configmap.yml`'s
  `analytics.woitzik.dev` `access_control` rule) except the tracker/ingest
  API paths under `/api/*`, `/track`, `/identify` etc. -- those stay open on
  both paths, or the tracker script can't load/report for anonymous
  visitors. See `docs/decisions/ADR-039-rybbit-public-tracker-exposure.md`
  for why that's an acceptable exposure.

## Egress

`allow-egress-cloudflared-rybbit` (cloudflared -> LXC:80) and
`allow-egress-nextcloud-authelia` live in
`kubernetes/apps/network-policies-egress.yml`, a loose file tracked by the
`apps-loose-manifests` Application, not the per-directory ApplicationSet --
apply it manually (`kubectl apply -f`) if a change here doesn't seem to take
effect after a merge.
