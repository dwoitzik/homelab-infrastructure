# ADR-011: Cloudflare Tunnel for external service exposure (Immich / photos.woitzik.dev)

**Date:** 2026-06-27
**Status:** Accepted

## Context

Immich (photo/video backup) needs to be reachable from outside the home network so family
members can back up photos via the mobile app without being on the VPN. This is the first
homelab service with an external-access requirement beyond what Headscale/VPN already
provides.

Options considered:

1. **VPN-only** — require every external user to install and stay connected to Headscale.
   Simple, no additional attack surface, but impractical for non-technical family members
   and breaks background photo sync when the VPN disconnects.

2. **Port-forward on the MikroTik** — expose port 2283 (or 443 with SNI routing) directly
   on the public IP. Simple to set up, but the public IP is not static (ISP changes it on
   router reboots), requires opening a firewall port on the perimeter router, and forces
   ongoing maintenance of the DDNS record. Traffic hits the Traefik VIP directly.

3. **Cloudflare Tunnel (existing infrastructure)** — a `cloudflared` daemon is already
   running in the cluster (originally for `cobblemon.woitzik.dev`). Adding a new ingress
   rule routes `photos.woitzik.dev` through the existing tunnel without opening any inbound
   firewall ports. Cloudflare handles DDoS, TLS termination, and acts as a reverse proxy
   in front of the cluster.

## Decision

Use the existing Cloudflare Tunnel. Add `photos.woitzik.dev` as a new ingress rule routing
to `http://immich-server.apps.svc.cluster.local:2283`.

The tunnel configuration and DNS record are managed by a new Terraform stack
(`terraform/stacks/cloudflare/`) using the Cloudflare provider v4, applied via Atlantis.

## Reasons

**No new firewall exposure:** The tunnel uses outbound-only connections from `cloudflared`
to Cloudflare's edge. No inbound port needs to be opened on the MikroTik. This is the
strongest argument — the alternative (port-forward) would be the first inbound hole in a
currently default-drop firewall.

**Static endpoint regardless of ISP IP:** External clients connect to
`photos.woitzik.dev`, which resolves to Cloudflare's anycast IPs. The homelab's public
IP never appears in DNS.

**Infrastructure already exists:** `cloudflared` is already deployed and running. Adding
an ingress rule is incremental, not a new component.

**DDoS/rate-limiting out of the box:** Cloudflare's proxy layer absorbs traffic spikes
before they reach the cluster.

## Trade-offs

- **Cloudflare dependency:** if Cloudflare is down (or the account is suspended), external
  access stops. Internal access (VPN or via `*.woitzik.dev` → Traefik wildcard) is
  unaffected.
- **Cloudflare sees the traffic:** photo upload traffic transits Cloudflare's network.
  For a family photo backup service this is acceptable; for sensitive data it would not be.
- **Split-DNS complexity:** the `*.woitzik.dev` wildcard AdGuard rewrite points to the
  Traefik VIP (`10.0.20.200`). `photos.woitzik.dev` goes to Cloudflare, not Traefik.
  This required adding specific A-record rewrites in AdGuard for Cloudflare's anycast IPs
  (`172.67.137.91`, `104.21.38.184`) so internal clients also route through the tunnel
  rather than hitting a dead Traefik backend. Per-domain upstreams do not work here —
  AdGuard's rewrites take priority over upstreams.
- **Immich has no Authelia layer:** Immich manages its own authentication. External users
  access `photos.woitzik.dev` directly and log in via Immich's own UI. This is intentional
  (family members should not need an Authelia account), but means Immich's own auth is the
  only barrier.

## Consequences

- `terraform/stacks/cloudflare/` manages tunnel config and DNS.
- `cloudflare_api_token` is stored in Ansible Vault and injected into Atlantis via
  `atlantis-secrets` k8s Secret (`TF_VAR_cloudflare_api_token`).
- AdGuard's Ansible template (`ansible/roles/adguard/templates/AdGuardHome.yaml.j2`)
  includes two specific A-record rewrites for `photos.woitzik.dev` that override the
  wildcard. If Cloudflare's anycast IPs change, update these rewrites.
- If a second service needs external access in future, add it as another ingress rule in
  `terraform/stacks/cloudflare/main.tf` — no new components needed.
