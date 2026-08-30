# ADR-039: Rybbit Public Tracker Exposure and OIDC SSRF Trade-offs

**Date:** 2026-08-30
**Status:** Accepted.

## Context

Rybbit (self-hosted web analytics for woitzik.dev) needs its tracker script
and event-ingest API reachable by anonymous browsers -- every client-side
analytics tool (Plausible, Umami, Fathom, Rybbit) has this same structural
requirement, since a visitor's browser has no Authelia session and can't
complete an SSO redirect.

## Decision: bypass Authelia for `analytics.woitzik.dev`'s `/api/*`

`kubernetes/apps/authelia/configmap.yml`'s `access_control` rules bypass
`/api/*` plus a few bare-path aliases (`/track`, `/identify`, ...) on the
LAN/Tailscale path. The public Cloudflare Tunnel path already bypasses
Traefik/Authelia entirely by design (ADR-033).

This is safe because Rybbit's own backend independently gates real
dashboard reads -- `GET /api/sites/1/overview` returns `403 Forbidden`
unauthenticated, verified directly against the LXC with no Authelia
involved. Authelia was only ever a redundant outer layer for the dashboard
UI, never the actual authorization boundary for the API. Bypassing it does
not expose anything Rybbit itself wasn't already going to protect.

Residual risk: anyone can POST junk events to `/api/track` (no auth on
ingest is inherent to this class of tool, not a gap specific to this
setup). Rybbit's own bot-detection filters non-browser requests into a
separate `bot_events` table rather than polluting real analytics.

## Decision: weaken SSRF protections for Jellyfin and Nextcloud OIDC

Both apps ship default SSRF guards that block outbound requests to private
IP ranges -- correct in general, but Authelia's own issuer
(`auth.woitzik.dev`) resolves to `10.0.20.200`, an internal address, so
OIDC discovery/token exchange can't work with the guard on.

- Jellyfin: `AllowPrivateNetworkAddresses: true`, scoped to the single
  `authelia` OIDC provider config only.
- Nextcloud: `allow_local_remote_servers: true`, a global setting --
  Nextcloud has no per-provider equivalent, so this affects every
  remote-URL feature (federation, external storage previews, etc.), not
  just `user_oidc`.

Both are admin-configured, not reachable via any anonymous/user-input
path, so this isn't a new attack surface for an external actor -- but it
is a real, intentional reduction in defense-in-depth, worth knowing about
before adding more OIDC providers on internal hostnames.

## Alternatives considered

**Log-based analytics instead of Rybbit** (parsing Traefik/Cloudflare
access logs into the existing Loki stack) would need zero new public
exposure, at the cost of losing client-side signals Rybbit provides
(screen size, SPA navigation, custom events, session replay). Not pursued
-- the richer data was worth the exposure, which is already minimal and
matches this repo's existing precedent (photos.woitzik.dev/Immich).
