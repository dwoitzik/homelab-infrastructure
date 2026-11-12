# Public exposure is an explicit allowlist (ADR-033): a hostname without a tunnel
# ingress rule and DNS record here is reachable only via LAN or the tailnet.
# cloudflared runs in-cluster (kubernetes/apps/cloudflared).

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
        hostname = "photos.woitzik.dev"
        # Public by design (ADR-033). Through Traefik so the CrowdSec bouncer
        # and rate limit on immich-final apply; no Authelia (mobile app).
        service = "https://traefik.kube-system.svc.cluster.local:443"
        origin_request = {
          origin_server_name     = "photos.woitzik.dev"
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
        hostname = "analytics.woitzik.dev"
        # Public by design (ADR-033): woitzik.dev visitors load the tracker.
        # Through Traefik so only the tracker endpoints are open and the
        # dashboard stays behind Authelia (ADR-074).
        service = "https://traefik.kube-system.svc.cluster.local:443"
        origin_request = {
          origin_server_name     = "analytics.woitzik.dev"
          no_tls_verify          = false
          connect_timeout        = 10
          tcp_keep_alive         = 30
          keep_alive_connections = 10
          http_host_header       = "analytics.woitzik.dev"
        }
      },
      # media.woitzik.dev -- Jellyfin, own login (native clients can't do the
      # Authelia redirect). Through Traefik for the bouncer and rate limit.
      {
        hostname = "media.woitzik.dev"
        service  = "https://traefik.kube-system.svc.cluster.local:443"
        origin_request = {
          origin_server_name = "media.woitzik.dev"
          no_tls_verify      = false
          http_host_header   = "media.woitzik.dev"
        }
      },
      # headscale is not here: its TS2021 Upgrade header is dropped by cloudflared
      # and Traefik (traefik#12609), so it uses a DNS-only record (below).
      # Every other hostname falls through to this 404 (ADR-033).
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

resource "cloudflare_dns_record" "tunnel_media" {
  zone_id = var.zone_id
  name    = "media"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Jellyfin -- routed via Cloudflare tunnel"
}

resource "cloudflare_dns_record" "tunnel_analytics" {
  zone_id = var.zone_id
  name    = "analytics"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Rybbit analytics -- routed via Cloudflare tunnel"
}

# headscale.woitzik.dev is DNS-only -- TS2021 registration can't traverse
# Cloudflare's proxy. Content tracks the dynamic WAN IP; the cloudflare-ddns
# CronJob (kubernetes/system/infrastructure/cloudflare-ddns.yml) owns it, ADR-059.
resource "cloudflare_dns_record" "dns_headscale_dmz" {
  zone_id = var.zone_id
  name    = "headscale"
  type    = "A"
  content = "192.0.2.1"
  proxied = false
  ttl     = 300
  comment = "DMZ direct WAN path, Tunnel incompatible w/ headscale TS2021"

  lifecycle {
    # The DDNS CronJob owns content; the placeholder only seeds a recreate.
    ignore_changes = [content]
  }
}

# Same underlying DNS record (already live-patched via API to match the
# config above) -- moved, not destroyed/recreated, so Terraform reconciles
# in place instead of flapping the record.
moved {
  from = cloudflare_dns_record.tunnel_headscale
  to   = cloudflare_dns_record.dns_headscale_dmz
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

# SRV so clients that support Minecraft service discovery reach the server as
# mc.woitzik.dev without an explicit port. Target tracks the same playit
# hostname as the CNAME above, so a playit reassignment updates both.
resource "cloudflare_dns_record" "mc_srv" {
  count    = var.mc_playit_hostname != "" ? 1 : 0
  zone_id  = var.zone_id
  name     = "_minecraft._tcp.mc"
  type     = "SRV"
  ttl      = 300
  priority = 0
  data = {
    priority = 0
    weight   = 5
    port     = 25565
    target   = var.mc_playit_hostname
  }
  comment = "SRV for mc.woitzik.dev -> playit.gg tunnel."
}

# =============================================================================
# Immich SSO via CF Access OIDC IdP (sign-in only, immich#8299). NOT
# TF-managed: stack token lacks Zero Trust Access (403); app + Immich OAuth
# client values created via admin API, documented in docs/SSO_SETUP.md.
# =============================================================================
