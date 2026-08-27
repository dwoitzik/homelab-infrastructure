# ADR-018: claude.woitzik.dev gets its own Cloudflare Tunnel, not a VLAN20→VLAN100 firewall hole

**Date:** 2026-08-14
**Status:** Superseded 2026-08-27 -- the tunnel and DNS record were removed
entirely. A dedicated tunnel avoided the VLAN-boundary problem this ADR
addresses, but a control-plane web terminal shouldn't be publicly routable
at all, regardless of what's in front of it. Tailscale (the host already
carries its own tailnet identity) is the remote-access path now.

## Context

After PR #436 (ADR-016/017's sibling — the wildcard tunnel/DNS fix) merged and was
applied, `claude.woitzik.dev` resolved correctly with a valid certificate, but requests
still 502'd. Traced live (David, via jump-box): a `curl` from a pod in the `apps`
namespace (VLAN20, `10.0.20.0/24`) to `ct-srv-claude-agent`'s ttyd (VLAN100/Admin,
`10.0.100.253:7681`) times out. `terraform/stacks/network/firewall_deterministic.tf`
rule `03` grants Admin → every internal VLAN; nothing grants the reverse. This isn't a
missing rule that should just be added — `docs/vlan-segmentation.md` documents VLAN 100
as **"Trusted Administrative Workstations"**, and rule 03's own comment confirms the
intended direction is Admin reaching *out*, not other zones reaching *in*.

`ct-srv-claude-agent` (this agent's own LXC, holding its SSH key, GitHub PAT, and
Tailscale identity) lives on that same Admin VLAN. VLAN20 is where every internet-facing
application in `docs/URL-INVENTORY.md` runs — the zone with, by construction, the largest
attack surface and the most third-party container images. Opening any hole from VLAN20
into VLAN100, even one scoped to a single port, means a compromise in any one of those
~45 apps gains a path toward the same network segment as this agent's credentials and
(per `docs/vlan-segmentation.md`) other trusted admin access. That's the exact blast-radius
expansion VLAN segmentation exists to prevent, and it's a different, worse risk than
"just" exposing ttyd itself (which already has its own password, sitting behind
CrowdSec+Authelia too).

## Decision

Give `claude.woitzik.dev` its own dedicated Cloudflare Tunnel, with its own `cloudflared`
connector process running directly on `ct-srv-claude-agent` (Admin VLAN), instead of
routing it through the shared cluster tunnel + Traefik like every other hostname. No
change to the firewall.

Concretely: a new `cloudflare_zero_trust_tunnel_cloudflared` + matching `..._config`
resource in `terraform/stacks/cloudflare/`, ingress `claude.woitzik.dev →
http://localhost:7681` (no Traefik hop), and an exact-match `claude` DNS CNAME
overriding the wildcard from PR #436 (exact records already take precedence over the
wildcard by design — see that record's own comment). The `claude-final`
IngressRoute/Service/Endpoints added in that same PR are removed — they can never
actually be reached given the decision above, so leaving them would be dead
configuration implying a path that doesn't exist.

## Reasons

- **Doesn't touch the VLAN boundary at all**, which is the point — rather than deciding
  how much of a hole is "narrow enough," this avoids the question. Admin still only ever
  originates connections outward (to Cloudflare's edge, same as it already does for
  everything else), never receives inbound from a lower-trust zone.
- **`cloudflared` connecting outbound to Cloudflare's edge needs no new firewall rule at
  all** — Admin already has full outbound/egress (confirmed live all session: this
  agent's own GitHub API and Cloudflare API calls originate from this exact host).
- **Consistent with why this LXC isn't Terraform/Ansible-managed like the rest of the
  fleet** (confirmed via repo grep — no `ct-srv-claude-agent` resource exists anywhere):
  it's already a deliberate, documented exception (the agent's own control host, not a
  homelab service), so giving it its own tunnel rather than folding it into the shared
  cluster-routed pattern is consistent with treating it as what it actually is.

## Trade-offs (accepted)

- A second `cloudflared` process/tunnel to keep running and updated, instead of reusing
  the cluster's existing one — genuine added surface, but isolated: if this tunnel or its
  credential is ever compromised, the blast radius is "this one hostname," not the shared
  tunnel serving all ~45 other services.
- The Cloudflare Tunnel *resource* is Terraform-managed (consistent with the rest of
  `terraform/stacks/cloudflare/`), but the `cloudflared` *process* running on
  `ct-srv-claude-agent` is configured directly on the host, not via Ansible — matching
  that host's existing out-of-IaC status rather than introducing partial, inconsistent
  coverage for a host that isn't otherwise managed that way.

## Consequences

- `kubernetes/system/apps-ingressroute.yml`'s `claude-final` IngressRoute and
  `external-claude-agent` Service/Endpoints (added in PR #436) are removed as dead
  configuration.
- New Terraform resources need an `atlantis apply` (same PR-then-apply gate as
  everything else) before the tunnel exists and has credentials to configure
  `cloudflared` with on the host.
- `docs/URL-INVENTORY.md`'s `claude.woitzik.dev` row updates: tunnel ingress rule is
  "dedicated (own tunnel)", not "wildcard" — noted there once this is live and tested.
