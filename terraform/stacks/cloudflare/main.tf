# =============================================================================
# Cloudflare Tunnel configuration for woitzik.dev public services.
#
# The cloudflared daemon runs in K3s (apps/cloudflared) and holds 4 persistent
# connections to Cloudflare's edge (fra/dus PoPs). This stack configures which
# hostnames are routed through that tunnel and creates the matching DNS records.
#
# Tunnel ID:  1f2e0f78-214b-4f59-881d-37e22625ae6e
# Account ID: 61863ddb47e05bc833c7671f69e3454c
# Zone:       woitzik.dev (1f15ed0f3a8b497302ba339dcab3c060)
# =============================================================================

# Provider v4 → v5 renames: moved blocks prevent destroy+recreate of live resources.
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

  # Public hostnames exposed through the Cloudflare tunnel.
  # Each entry maps a public hostname → internal K3s service.
  # cloudflared resolves these from within the apps namespace.
  tunnel_ingress = [
    {
      hostname = "photos.woitzik.dev"
      service  = "http://immich-server.apps.svc.cluster.local:2283"
    },
  ]
}

# -----------------------------------------------------------------------------
# Tunnel ingress configuration
# Defines which hostnames cloudflared routes and where traffic lands internally.
# -----------------------------------------------------------------------------
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config {
    dynamic "ingress_rule" {
      for_each = local.tunnel_ingress
      content {
        hostname = ingress_rule.value.hostname
        service  = ingress_rule.value.service
        origin_request {
          no_tls_verify    = false
          connect_timeout  = "10s"
          tcp_keep_alive   = "30s"
          http_host_header = ingress_rule.value.hostname
          # Immich uploads large photo/video files — chunked encoding prevents
          # Cloudflare from buffering the entire body before forwarding, which
          # causes ECONNRESET on large uploads. write_timeout covers the upload
          # leg; read_timeout covers the origin's processing response.
          chunked_encoding = true
          write_timeout    = "600s"
          read_timeout     = "120s"
        }
      }
    }
    # Catch-all: return 404 for any unmatched hostname
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# -----------------------------------------------------------------------------
# DNS records — CNAME → tunnel (proxied through Cloudflare CDN/DDoS layer)
# -----------------------------------------------------------------------------
resource "cloudflare_dns_record" "tunnel_photos" {
  zone_id = var.zone_id
  name    = "photos"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  comment = "Immich photo library — routed via Cloudflare tunnel"
}
