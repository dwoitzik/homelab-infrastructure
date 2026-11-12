# ADR-074: Rybbit's public path goes through Traefik, with only the tracker endpoints open

**Date:** 2026-11-12
**Status:** Accepted. Supersedes the Authelia-bypass part of
[ADR-039](ADR-039-rybbit-public-tracker-exposure.md).

## Context

ADR-039 left `analytics.woitzik.dev` with two different security postures:

- **Public** (Cloudflare Tunnel): the tunnel ingress pointed straight at the
  LXC (`http://10.0.20.205:80`). No CrowdSec, no rate limit, no Authelia. The
  whole app was on the internet, including the dashboard and the email/password
  login (`/login` returned 200 from a public resolver).
- **LAN/Tailscale** (Traefik): CrowdSec and Authelia, but Authelia bypassed the
  whole `/api/*` tree, which includes `/api/auth/*` (login) and `/api/admin/*`.

Rybbit's login has no second factor (better-auth email/password, one user), so
the only things between the internet and the analytics data were that one
password and better-auth's own per-IP rate limit.

The tracker served to woitzik.dev visitors needs far less than `/api/*`. The
script (`/api/script.js`) and the backend routes marked public in
`server/src/index.ts` come down to:

| Path | Used by |
|---|---|
| `GET /api/script.js`, `/api/replay.js`, `/api/metrics.js` | script loads |
| `POST /api/track`, `/api/identify` | page views, events, identify |
| `GET /api/site/tracking-config/<site>` | script config fetch |
| `POST /api/site/<site>/feature-flags/evaluate` | feature flags |
| `POST /api/session-replay/record/<site>` | session replay |
| `GET /api/health` | external probe |

## Decision

1. The tunnel ingress for `analytics.woitzik.dev` points at Traefik
   (`terraform/stacks/cloudflare/main.tf`), like `photos` and `media`.
2. `rybbit-final` (`kubernetes/system/apps-ingressroute.yml`) has two routes:
   the paths above with `crowdsec-bouncer` + `rybbit-ratelimit`, and everything
   else with `crowdsec-bouncer` + `authelia`.
3. The Authelia `bypass` rule for `analytics.woitzik.dev` is removed. The
   tracker requests never reach Authelia, so the rule had no job left except
   opening the login and admin APIs.

## Reasons

- The dashboard is an admin tool, like every other service ADR-033 keeps off
  the internet. From outside, Authelia's redirect goes to `auth.woitzik.dev`,
  which has no public record, so the dashboard is effectively LAN/Tailscale
  only. That is the intended state, not a side effect.
- The tracker routes get the same CrowdSec and per-visitor rate limit as the
  other public hostnames, keyed on `Cf-Connecting-Ip`.
- Splitting the routes in Traefik rather than in Authelia keeps the tracker
  independent of Authelia: if Authelia is down, page views are still recorded.
- Rybbit resolves the visitor IP from `Cf-Connecting-Ip`, which Traefik and
  Caddy pass through untouched, so geolocation is unchanged.

## Trade-offs

- The dashboard can no longer be opened from the internet without Tailscale.
- A new public endpoint in a Rybbit release (a new script feature) fails
  closed: it hits the Authelia route and returns a redirect until it is added to
  the tracker route. `ExternalProbeFailed` only covers `/api/health`, so check
  the browser console on woitzik.dev after a Rybbit update.
- Tracking now also depends on Traefik and CrowdSec, as photos and media
  already do.

## Consequences

- `allow-egress-cloudflared-rybbit` in
  `kubernetes/apps/network-policies-egress.yml` becomes unused once the tunnel
  change is applied and is removed in a follow-up.
- After changing the Authelia config, the Authelia pods need a restart: it does
  not reload `access_control` on its own.
