# =============================================================================
# Cloudflare Tunnel configuration for woitzik.dev public services.
# Last applied: 2026-07-01 (media tunnel + mc CNAME via playit.gg)
#
# The cloudflared daemon runs in K3s (apps/cloudflared) and holds 4 persistent
# connections to Cloudflare's edge (fra/dus PoPs). This stack configures which
# hostnames are routed through that tunnel and creates the matching DNS records.
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
        hostname = "atlantis.woitzik.dev"
        # SEC-008 regression fix (2026-07-05): ADR-012 moved Atlantis off k3s
        # onto its own LXC (ct-srv-atlantis-01, 10.0.20.250) and this ingress
        # entry was repointed straight at the LXC's IP -- bypassing Traefik
        # and, with it, the Authelia gate SEC-008 originally added. Atlantis
        # has no auth of its own; confirmed live this served its full UI
        # (PR history, plan/apply state, lock controls) to an unauthenticated
        # public request. Routed back through Traefik so the Authelia
        # middleware on atlantis-final (apps-ingressroute.yml) actually
        # applies -- unlike photos/media below, Atlantis has no native login
        # to fall back on, so it can't use the direct-to-service pattern.
        # port 80 (Traefik's plain-HTTP entrypoint) redirects to https
        # globally -- the tunnel doesn't follow redirects like a browser, it
        # just relays them, causing an infinite loop back through Cloudflare.
        # Hit Traefik's websecure (443) entrypoint directly instead; its
        # *.woitzik.dev cert is valid for this hostname so no_tls_verify
        # stays false.
        service = "https://traefik.kube-system.svc.cluster.local:443"
        origin_request = {
          no_tls_verify          = false
          connect_timeout        = 10
          tcp_keep_alive         = 30
          keep_alive_connections = 10
          http_host_header       = "atlantis.woitzik.dev"
          # Without this, cloudflared expects the origin's TLS cert to match
          # the service hostname (traefik.kube-system.svc.cluster.local) and
          # fails verification against Traefik's *.woitzik.dev cert -- a 502
          # confirmed live before adding this.
          origin_server_name       = "atlantis.woitzik.dev"
          disable_chunked_encoding = false
        }
      },
      {
        hostname = "photos.woitzik.dev"
        service  = "http://immich-server.apps.svc.cluster.local:2283"
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
      {
        # Jellyfin — routed via tunnel so FritzBox-WLAN and external clients
        # reach it without open WAN port forwards. Jellyfin's own login gates
        # access on this path (same pattern as photos.woitzik.dev/Immich).
        # Authelia SSO still applies on the internal Traefik path.
        hostname = "media.woitzik.dev"
        service  = "http://jellyfin.apps.svc.cluster.local:8096"
        origin_request = {
          no_tls_verify            = false
          connect_timeout          = 10
          tcp_keep_alive           = 30
          keep_alive_connections   = 10
          http_host_header         = "media.woitzik.dev"
          disable_chunked_encoding = false
        }
      },
      # Catch-all: return 404 for any unmatched hostname
      { service = "http_status:404" }
    ]
  }
}

# -----------------------------------------------------------------------------
# DNS records -- CNAME -> tunnel (proxied through Cloudflare CDN/DDoS layer)
#
# ttl = 1 means "Auto" for proxied records (required field in provider v5).
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

resource "cloudflare_dns_record" "tunnel_atlantis" {
  zone_id = var.zone_id
  name    = "atlantis"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Atlantis GitOps runner -- GitHub webhook endpoint (/events) + UI"
}

resource "cloudflare_dns_record" "tunnel_media" {
  zone_id = var.zone_id
  name    = "media"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Jellyfin media server -- routed via Cloudflare tunnel"
}

# auth.woitzik.dev -- Authelia, gating almost every other exposed service.
# docs/IAC-GAPS.md item 4: the highest-consequence record in the zone that
# wasn't under Terraform (26 of ~30 records still aren't, imported one at a
# time per that doc rather than in bulk, to keep each diff reviewable and
# avoid a live DNS blip if a representation doesn't exactly match on first
# plan). NOT a Cloudflare Tunnel CNAME like the others above -- rides
# home.woitzik.dev's dynamic-DNS chain (direct WAN access), not proxied.
#
# Merged 2026-07-07 (PR #335) with the import{} block below already clean
# (1 to import, 1 comment-only change) -- but the actual `terraform apply`
# that performs the import hasn't run yet. Pending explicit per-project
# authorization before applying.
resource "cloudflare_dns_record" "auth" {
  zone_id = var.zone_id
  name    = "auth"
  type    = "CNAME"
  content = "home.woitzik.dev"
  proxied = false
  ttl     = 1
  comment = "Authelia SSO -- gates almost every other exposed service"
}

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

# cobblemon.woitzik.dev -- exposed-service hardening pass (2026-07-08),
# docs/IAC-GAPS.md-class finding: zero IaC trail, and stale. Both port
# forwards for Minecraft (25565) and Cobblemon (25566) were removed
# 2026-07-01 (see terraform/stacks/network/nat_portforward.tf) -- 25565 was
# replaced by the playit.gg tunnel above, but 25566 was deliberately made
# internal-only with no replacement external path. This A record predates
# that removal and was never cleaned up: confirmed it's dead, not a live
# exposure -- points at 178.202.47.0 while home.woitzik.dev's real current
# DDNS IP is different (178.202.46.102, checked live), and the port itself
# doesn't respond at the stale IP either. Bringing it under Terraform first
# (this import) rather than deleting it directly outside IaC; recommend a
# deliberate follow-up to actually remove it once reviewed, not bundled
# here.
resource "cloudflare_dns_record" "cobblemon_stale" {
  zone_id = var.zone_id
  name    = "cobblemon"
  type    = "A"
  content = "178.202.47.0"
  proxied = false
  ttl     = 300
  comment = "STALE -- confirmed dead 2026-07-08, port-forward removed 2026-07-01, recommend deletion"
}
