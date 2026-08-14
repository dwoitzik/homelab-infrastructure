# ADR-019: Public exposure is an explicit allowlist of two hostnames, not a wildcard

**Date:** 2026-08-14
**Status:** Accepted

## Context

PR #436 (this same session) fixed "services deployed but URLs don't work" with a
single wildcard Cloudflare Tunnel ingress rule + wildcard DNS record: any hostname
declared in this repo's IngressRoutes automatically became internet-reachable, gated
only by whatever Traefik middleware that specific route happened to declare. That's an
**opt-out** model — public by default, private only if something explicitly narrows it.

Once #436 was live, the operator raised the concern directly: this default is backwards
for a homelab. Investigating it properly (an exposure audit across all 46 declared
hostnames, cross-referencing Traefik middleware) found the concern was justified —
several hostnames had no Authelia gate and only their own app-level auth, and at least
one (`requests.woitzik.dev`, Jellyseerr) had no protection at all, not even CrowdSec:

| Hostname | Own auth | Gap class |
|---|---|---|
| `vault.woitzik.dev` (Vaultwarden) | own 2FA | plausible remote-access need |
| `headscale.woitzik.dev` | own device auth flow | **needs** to be public (see below) |
| `s3.woitzik.dev` (Garage) | S3 signed-request keys | protocol requires direct API access |
| `photos.woitzik.dev` (Immich) | mobile app token | documented, deliberate (family access) |
| `media.woitzik.dev` (Jellyfin) | own login | documented, deliberate (native app clients) |
| `matrix.woitzik.dev` (Synapse) | federation protocol | protocol requires unauthenticated inbound |
| `wazuh.woitzik.dev` (SIEM) | own login only | **no plausible reason to be public at all** |
| `nextcloud.woitzik.dev` | own login only | **no plausible reason to be public at all** |
| `requests.woitzik.dev` (Jellyseerr) | none | **no protection of any kind** |

This table is itself the argument for the decision below: an opt-out model means every
new app, every IngressRoute added without thinking hard about exposure, is public
until someone notices and narrows it — and three real gaps had already accumulated in
the single day this wildcard existed.

This directly extends `ADR-018`'s reasoning (why `claude.woitzik.dev` got its own
dedicated tunnel instead of a VLAN20→VLAN100 firewall hole, rather than accepting even
a narrow cross-zone exception): the operator's instinct there — don't open a hole
between a higher-exposure zone and a lower-exposure one, no matter how narrow — applies
identically to the public internet as a whole, which is the highest-exposure zone of
all relative to this homelab's LAN/VPN.

## Decision

The Cloudflare Tunnel's ingress config is an explicit allowlist of exactly two
hostnames:

- **`photos.woitzik.dev`** (Immich) — family access to the photo library from outside
  the LAN/VPN is a real, named use case, not a hypothetical one.
- **`headscale.woitzik.dev`** — structurally required: a device re-authenticating or
  joining the Tailscale mesh has to reach the control plane *before* any VPN path to it
  exists. This is the one hostname on this list that cannot be VPN-only by definition.

Every other hostname declared across this repo's IngressRoutes — all ~44 others,
including Vaultwarden, Nextcloud, Jellyfin, Grafana, Vault, PVE, PBS, Wazuh, Atlantis,
Authelia itself, everything — gets no Cloudflare DNS record and no tunnel ingress rule.
Reachable via LAN or Headscale/Tailscale VPN only, through the AdGuard split-horizon
rewrite to Traefik's ClusterIP LoadBalancer (`10.0.20.200`) that every internal client
already uses — a path that never touches Cloudflare or the public internet, so nothing
about LAN/VPN access changes.

`auth.woitzik.dev` (Authelia) specifically: checked before dropping it, not assumed.
Neither `headscale-final`'s nor `immich-final`'s Traefik route uses the `authelia`
middleware (confirmed via `kubectl get ingressroute.traefik.io`) — so with only these
two hostnames public, nothing publicly reachable depends on Authelia's forward-auth
redirect completing against a publicly-resolvable `auth.woitzik.dev`. Safe to drop.
Internal Authelia login (everything on the LAN/VPN path) is unaffected — that resolves
`auth.woitzik.dev` via the same internal AdGuard rewrite as everything else, never
Cloudflare's public DNS.

## Reasons

- **Default-deny is the correct posture for a homelab's public attack surface**,
  same principle as the MikroTik firewall's own forward/input chains (default-drop,
  explicit allows only) — this just applies it one layer up, at the DNS/tunnel level
  rather than the network level.
- **The exposure audit found real, accumulating gaps in under a day** under the
  opt-out model — Wazuh, Nextcloud, and Jellyseerr had no good reason to be
  internet-reachable and were, simply because nothing said otherwise. An allowlist
  can't accumulate gaps the same way: a new IngressRoute is private until someone
  makes a deliberate choice to add it here, not the reverse.
- **Only one hostname is structurally required to be public** (Headscale, for the
  reason above). Everything else's "need" to be public was either a convenience
  (Vaultwarden, Nextcloud — both usable via Tailscale from anywhere with the app
  installed) or genuinely accidental (Wazuh, Jellyseerr, the ~40 hosts the wildcard
  swept up without anyone deciding they should be public).
- **LAN/VPN access is unaffected.** This is a change to public reachability only — the
  AdGuard rewrite + Traefik LB path every local and Tailscale-connected client already
  uses doesn't touch Cloudflare at all, confirmed by how this repo's own internal
  testing works throughout this recovery (every `dig` from inside the network resolves
  these hostnames to `10.0.20.200`, never Cloudflare's edge).

## Trade-offs (accepted)

- Away-from-home access to Vaultwarden, Nextcloud, Immich (still public), Grafana, or
  anything else now requires the Tailscale/Headscale VPN client running — a real
  convenience cost versus "just open the URL," but the operator's own stated intent is
  exactly this: nothing except the two named exceptions should be reachable without it.
- Photos (Immich) staying public keeps its existing risk profile (mobile app
  token auth, no Authelia) — unchanged from before this ADR, not newly introduced by it.
- Future new services need a deliberate decision to add them to this allowlist, not
  just an IngressRoute — a small amount of added process, in exchange for the
  default-deny guarantee.

## Consequences

- `terraform/stacks/cloudflare/main.tf`: wildcard ingress rule + wildcard DNS record
  removed; `atlantis`, `auth`, `home` DNS records removed (Atlantis, Authelia, and
  Homepage all move to VPN/LAN-only reachability); a new explicit `headscale.woitzik.dev`
  ingress rule + DNS record added (previously only covered by the wildcard).
- `terraform/stacks/cloudflare/imports.tf`: `tunnel_atlantis` and `tunnel_home` import
  blocks removed along with their resources.
- `docs/URL-INVENTORY.md` needs a fresh pass once this is applied: every hostname
  except `photos.woitzik.dev` and `headscale.woitzik.dev` becomes "PASS via LAN/VPN,
  no public DNS by design" rather than a FAIL or a PARKED-pending-fix row.
- The Wazuh/Nextcloud/Jellyseerr middleware gaps that motivated this audit are now
  moot for public exposure (they're not public at all), but the underlying question —
  should they have Authelia in front of them for LAN/VPN access too, as
  defense-in-depth against a compromised device already on the network — is a
  legitimate separate follow-up, not addressed by this ADR.
