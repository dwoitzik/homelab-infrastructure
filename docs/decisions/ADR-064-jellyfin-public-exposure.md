# ADR-064: Jellyfin is promoted to the public allowlist via the Cloudflare Tunnel

## Status

Accepted, 2026-10-19. Applied out-of-band the same day (see "Out-of-band apply" below);
the Terraform state still expects the human-gated `atlantis apply -d cloudflare`.

## Context

`media.woitzik.dev` (Jellyfin) has been LAN/VPN-only since `ADR-033` narrowed the
Cloudflare Tunnel to an explicit allowlist. Its `media-final` IngressRoute carries no
Authelia middleware because Jellyfin's native clients (Android, iOS, Android TV) cannot
follow Authelia's browser SSO redirect — access is gated on Jellyfin's own login. The
operator asked for Jellyfin to be reachable from outside the home, the same way
`photos.woitzik.dev` (Immich) already is: through the existing Cloudflare Tunnel, under
the same "own auth, no Authelia" model `ADR-033` and `ADR-011` established for apps whose
clients can't do forward-auth.

The pieces were already in place: Authelia even has a `jellyfin` OIDC client pre-provisioned
for an optional SSO-Auth plugin, the tunnel is configured declaratively in
`terraform/stacks/cloudflare/main.tf`, and the `apps` namespace already has the
`default-deny-egress` NetworkPolicy model (with a matching raw-LAN-IP carve-out pattern
established for the Rybbit ingress, `allow-egress-cloudflared-rybbit`).

## Decision

Add exactly one hostname to the public allowlist:

- **Tunnel ingress + DNS** (`terraform/stacks/cloudflare/main.tf`): a `media.woitzik.dev`
  ingress rule pointing straight at the GPU-passthrough LXC's LAN IP
  (`http://10.0.20.254:8096`, the raw-IP shape already used for the Rybbit/analytics
  route), plus a proxied `media` CNAME to the tunnel. A single explicit hostname, no
  wildcard — the same allowlist discipline as `ADR-033`.
- **NetworkPolicy** (`kubernetes/apps/network-policies-egress.yml`): an explicit
  `allow-egress-cloudflared-jellyfin` rule. Jellyfin is an LXC, not an in-cluster pod, so
  cloudflared's default-deny egress does not cover it — same gap class as the rybbit rule
  directly above it.
- **Rate limiting** (`kubernetes/apps/jellyfin/middleware.yml`, applied on `media-final`):
  a `jellyfin-ratelimit` Traefik middleware mirroring `immich-ratelimit`, keyed on
  Cloudflare's `Cf-Connecting-Ip` header so each real client gets its own bucket rather
  than sharing the cloudflared pod's.

## Consequences

- Jellyfin becomes reachable from the public internet through the same tunnel, WAF and
  DDoS protection that already front `photos`. The public path is gated by Jellyfin's own
  login — identical to the Immich precedent, and the reason Authelia is deliberately not
  stacked in front of either.
- The tunnel ingress points straight at the LXC, bypassing Traefik — so, exactly as with
  Immich today, `jellyfin-ratelimit` only takes effect on the LAN/VPN path, not the public
  one. This is a known, pre-existing property of the direct-to-origin tunnel shape this
  repo already uses for Immich, not a regression introduced here; Cloudflare's edge WAF is
  the public-path equivalent. Revisiting it (routing the tunnel through Traefik so the
  middleware applies publicly) is a larger change deferred to a future ADR.
- The exposure is one explicit hostname, reversible by removing the ingress rule, the DNS
  record, and the NetworkPolicy rule — a PR + `atlantis apply -d cloudflare`, no
  destructive operation in either direction.
- `docs/EXPOSURE.md`, `docs/URL-INVENTORY.md` and the top-level `README.md` service table
  are updated in the same change so the public-hostname whitelist stays the source of
  truth.

## Out-of-band apply (2026-10-19)

The change had already merged to `main`, but it couldn't wait on the `terraform-apply`
gate: GitHub reported degraded availability for Actions, Pages and Webhooks, so neither
the Atlantis plan nor the merge-time workflow could run. The `cloudflare` stack's tunnel
ingress and `media` DNS record were therefore applied directly through the Cloudflare API
(token held on `ct-srv-atlantis-01`, never logged); the Kubernetes half
(`allow-egress-cloudflared-jellyfin`, the `media-final` route, `jellyfin-ratelimit`) had
already auto-synced from `main` via ArgoCD, so no cluster change was needed. The public
path was verified end to end (`302 -> web/`, `server: Kestrel`) before this note.

This bypassed the merge-to-apply convention, not the `terraform-apply` environment gate —
that still stands, and the stack still expects to be applied normally. The one lasting
artifact is the out-of-band DNS record: a one-time `import` block in
`terraform/stacks/cloudflare/imports.tf` adopts it so the next gated apply is idempotent
instead of colliding on Cloudflare's "record already exists" error. Remove that block once
that apply has landed.
