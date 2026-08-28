# =============================================================================
# Cloudflare Tunnel configuration for woitzik.dev public services.
#
# 2026-08-14 (ADR-019): rewritten from a "public by default, opt out" wildcard
# to an explicit allowlist of exactly two hostnames. Everything else in this
# repo's ~46 declared IngressRoutes is reachable only via LAN or Headscale/
# Tailscale VPN (the existing AdGuard rewrite to Traefik's ClusterIP LB,
# 10.0.20.200, which never touches this tunnel or the public internet at
# all) -- same reasoning as ADR-018 (why claude.woitzik.dev got its own
# tunnel instead of a VLAN20->VLAN100 firewall hole), extended from "which
# network zone" to "the public internet as a whole." See ADR-019 for the
# full exposure audit this rewrite is based on.
#
# The cloudflared daemon runs in K3s (apps/cloudflared) and holds persistent
# connections to Cloudflare's edge. This stack configures which hostnames are
# routed through that tunnel and creates the matching DNS records -- if a
# hostname has neither, it simply isn't reachable from outside the LAN/VPN,
# which is now the deliberate default rather than something to opt into.
#
# Tunnel ID:  1f2e0f78-214b-4f59-881d-37e22625ae6e
# Account ID: 61863ddb47e05bc833c7671f69e3454c
# Zone:       woitzik.dev (1f15ed0f3a8b497302ba339dcab3c060)
# =============================================================================

# Provider v4 -> v5 renames: moved blocks prevent destroy+recreate of live resources.
moved {
  from = cloudflare_tunnel_config.homelab
  to   = cloudflare_zero_trust_tunnel_cloudflared_config.homelab
}

moved {
  from = cloudflare_record.tunnel_photos
  to   = cloudflare_dns_record.tunnel_photos
}

locals {
  tunnel_cname = "${var.tunnel_id}.cfargotunnel.com"
}

# claude.woitzik.dev -- removed. This fronted a web terminal onto the
# recovery agent's own control host, which should never have been on the
# public internet regardless of what sat in front of it. Tailscale (the
# host already has its own tailnet node) is the intended remote-access path.
# -----------------------------------------------------------------------------
# Tunnel ingress configuration
# v5 schema: config is an object attribute (config = {}) not a block (config {}).
# ingress is a list attribute -- not dynamic ingress_rule blocks.
# Timeouts are integers (seconds). disable_chunked_encoding replaces chunked_encoding
# (inverted bool: false = chunked encoding ENABLED, which is what we want).
# -----------------------------------------------------------------------------
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config = {
    ingress = [
      {
        hostname = "photos.woitzik.dev"
        # Family access to the Immich photo library -- explicitly named by
        # the operator as one of exactly two hostnames that should be
        # publicly reachable (ADR-019). Routed directly to the Immich Service,
        # not through Traefik -- Immich has no external auth in front of it
        # (mobile app needs API-token auth, not Authelia's browser redirect).
        service = "http://immich-server.apps.svc.cluster.local:2283"
        origin_request = {
          no_tls_verify          = false
          connect_timeout        = 10
          tcp_keep_alive         = 30
          keep_alive_connections = 10
          http_host_header       = "photos.woitzik.dev"
          # disable_chunked_encoding = false keeps chunked encoding ON, preventing
          # Cloudflare from buffering the full upload body before forwarding --
          # the root cause of ECONNRESET on large Immich uploads (REL-026).
          disable_chunked_encoding = false
        }
      },
      # headscale.woitzik.dev: removed from this tunnel's ingress 2026-08-28.
      # Headscale's ts2021/noise registration protocol upgrades the
      # connection with `Upgrade: tailscale-control-protocol`, not the
      # literal `websocket` value. Neither Traefik
      # (github.com/traefik/traefik#12609) nor cloudflared itself forward a
      # non-"websocket" Upgrade header -- confirmed live (repeated 500s "no
      # upgrade header in TS2021 request") and in headscale's own docs
      # ("Running Headscale behind a Cloudflare Proxy or Tunnel is not
      # supported"). Moved to a direct WAN path via the DMZ reverse proxy
      # instead (nginx forwards $http_upgrade unconditionally) -- see
      # dns_headscale_dmz below and terraform/stacks/network/nat_portforward.tf.
      # Every other hostname: no ingress entry, no route through this tunnel
      # at all. Falls through to this 404 -- the deliberate default per
      # ADR-019, not a gap to fill in later. LAN/Tailscale clients reach
      # these exact same services fine via the existing AdGuard rewrite to
      # Traefik's ClusterIP LB (10.0.20.200), which never touches Cloudflare.
      { service = "http_status:404" }
    ]
  }
}

# -----------------------------------------------------------------------------
# DNS records. photos.woitzik.dev is CNAME -> tunnel (proxied through
# Cloudflare CDN/DDoS layer, ttl = 1 means "Auto", required for proxied
# records in provider v5). headscale.woitzik.dev is DNS-only, see below.
# -----------------------------------------------------------------------------
resource "cloudflare_dns_record" "tunnel_photos" {
  zone_id = var.zone_id
  name    = "photos"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Immich photo library -- routed via Cloudflare tunnel"
}

# 2026-08-28: no longer routed through the tunnel (see the removed ingress
# comment above) -- points straight at the MikroTik's Cloudflare-Cloud DDNS
# hostname (routeros_ip_cloud.ddns in the network stack; that stack has no
# output wired to this one, so the value is copied here, not referenced).
# DNS-only (not proxied): traffic goes WAN -> FritzBox port-forward (manual,
# not IaC-managed) -> MikroTik dst-nat -> DMZ nginx reverse proxy, matching
# nat_portforward.tf's dstnat_headscale_dmz.
resource "cloudflare_dns_record" "dns_headscale_dmz" {
  zone_id = var.zone_id
  name    = "headscale"
  type    = "CNAME"
  content = "ec190fe6b6ab.sn.mynetname.net"
  proxied = false
  ttl     = 300
  comment = "DMZ direct WAN path, Tunnel incompatible w/ headscale TS2021"
}

# Same underlying DNS record (already live-patched via API to match the
# config above) -- moved, not destroyed/recreated, so Terraform reconciles
# in place instead of flapping the record.
moved {
  from = cloudflare_dns_record.tunnel_headscale
  to   = cloudflare_dns_record.dns_headscale_dmz
}

# 2026-08-14 (ADR-019): atlantis, auth, home, and the *.woitzik.dev wildcard
# DNS records were removed here. The operator's explicit instruction: only
# photos.woitzik.dev and headscale.woitzik.dev (above) should have any public
# DNS/tunnel exposure at all. Every other hostname declared in this repo's
# IngressRoutes -- including atlantis, auth, home, and everything the
# wildcard used to catch -- is reachable only via LAN or Headscale/Tailscale
# VPN through the existing AdGuard rewrite to Traefik's ClusterIP LB
# (10.0.20.200), which never touches Cloudflare or the public internet. See
# ADR-019 for the full exposure audit and reasoning.

# mc.woitzik.dev -> playit.gg tunnel for Minecraft (port 25565, main server).
# Only created once var.mc_playit_hostname is set in tfvars.
# Set up playit agent on ct-dmz-games-01 first, then fill in the hostname.
resource "cloudflare_dns_record" "mc_playit" {
  count   = var.mc_playit_hostname != "" ? 1 : 0
  zone_id = var.zone_id
  name    = "mc"
  type    = "CNAME"
  # Not proxied -- Minecraft TCP traffic can't go through Cloudflare CDN.
  content = var.mc_playit_hostname
  proxied = false
  ttl     = 300
  comment = "Minecraft server -- routed via playit.gg tunnel (not CF tunnel)"
}

# cobblemon.woitzik.dev -- previously tracked here as a stale record pending
# deletion (see git history for the original comment/import). 2026-08-14:
# confirmed via the Cloudflare API that it no longer exists live -- already
# deleted out-of-band since that note was written. Dropped from Terraform
# entirely rather than recreating a record whose own history said to remove
# it.

# =============================================================================
# Cloudflare Access (Zero Trust) in front of photos.woitzik.dev.
# 2026-08-17: BRIEFING-V4.md Section 1.4 / Section B. Immich has no external
# auth of its own in front of it (the rate limit in kubernetes/apps/immich/
# middleware.yml is abuse mitigation, not authentication) -- this puts a real
# identity gate at Cloudflare's edge, before any request reaches the tunnel
# at all. One-time PIN (email OTP) is Cloudflare's built-in identity method,
# no separate IdP needed.
#
# Known, accepted trade-off (documented, not silently worked around): this
# gates the ENTIRE app, including the API paths the Immich mobile app calls
# directly with its own bearer-token auth, not a browser session Access can
# recognize. The brief's own instruction ("Immich itself is invisible to
# everyone else") does not carve out an exception for the mobile app, so this
# implements it literally. Practical effect: family members can still use the
# mobile app freely from inside the LAN or over Tailscale (this Access
# Application only ever sees traffic that comes in through the public
# Cloudflare Tunnel, not LAN/VPN traffic, which never touches Cloudflare at
# all -- see the tunnel-scoping comment at the top of this file). External
# mobile-app access (cellular data, off the family WiFi and off Tailscale)
# will need either a one-time browser-based Access login first (session
# persists) or the family member on Tailscale. If this proves too disruptive
# in practice, the fix is a second, path-scoped Access Application or a
# Service Token for the app specifically -- a deliberate follow-up, not
# implemented blind here.
resource "cloudflare_zero_trust_access_application" "immich" {
  account_id                = var.account_id
  name                      = "Immich (photos.woitzik.dev)"
  domain                    = "photos.woitzik.dev"
  type                      = "self_hosted"
  session_duration          = "24h"
  auto_redirect_to_identity = true
  allowed_idps              = [] # empty = all IdPs enabled on the account, incl. One-time PIN

  # v5 schema: policies are defined inline on the application (a nested list
  # attribute), not as a separate resource linked by an application_id --
  # confirmed against the actual provider schema (`terraform providers
  # schema -json`), not guessed; there is no `application_id` argument on
  # cloudflare_zero_trust_access_policy in this provider version.
  policies = [
    {
      name     = "Family email OTP"
      decision = "allow"
      # Each `include` entry is OR'd; an `email` rule takes exactly one
      # address -- one entry per family member, not a list inside one rule.
      include = [
        for addr in var.immich_access_family_emails : {
          email = { email = addr }
        }
      ]
    }
  ]
}
