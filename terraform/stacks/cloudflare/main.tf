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
      {
        # 2026-08-14 Phase 6 URL audit: every other *.woitzik.dev hostname
        # (home, ha, status, gitea, nextcloud, auth, ~40 more) was declared in
        # kubernetes/ IngressRoutes but had NO entry here at all -- cloudflared
        # matches top-to-bottom and falls through to the 404 catch-all below
        # for anything not explicitly listed, so those hosts were 404ing at
        # the tunnel itself, before ever reaching Traefik. This wildcard is
        # the general-case fix: route anything not already special-cased above
        # (atlantis/photos/media, which need per-host origin tuning) through
        # Traefik, which already does its own host-based routing plus
        # CrowdSec/Authelia per IngressRoute -- same pattern the atlantis fix
        # above uses, just generalized.
        #
        # 2026-08-14 correction: the original version of this rule left
        # origin_server_name unset on the assumption that cloudflared would
        # auto-fill TLS SNI to match each request's real hostname for a
        # wildcard rule. That assumption was wrong -- confirmed live via
        # `kubectl logs` on the cloudflared pod: every request through this
        # rule failed with "certificate is valid for *.woitzik.dev,
        # woitzik.dev, not traefik.kube-system.svc.cluster.local" (a 502 for
        # all ~44 hosts behind this rule). cloudflared verifies the origin's
        # TLS cert against the origin's *service* hostname by default when
        # origin_server_name is unset, same as the atlantis rule above needed
        # explicitly -- there's no dynamic-per-request SNI behavior for
        # wildcard rules. Fix: a static origin_server_name works fine here
        # precisely because it doesn't need to match the request -- Traefik's
        # wildcard cert's SAN list is `*.woitzik.dev, woitzik.dev` (checked via
        # openssl), so verifying against the bare apex "woitzik.dev" succeeds
        # for every subdomain uniformly. http_host_header stays unset
        # deliberately (confirmed working correctly via the same logs --
        # `dest=https://status.woitzik.dev/` etc. showed the real per-request
        # hostname reaching the origin) -- only the TLS verification target
        # needed to be fixed, not the routing.
        hostname = "*.woitzik.dev"
        service  = "https://traefik.kube-system.svc.cluster.local:443"
        origin_request = {
          no_tls_verify            = false
          connect_timeout          = 10
          tcp_keep_alive           = 30
          keep_alive_connections   = 10
          origin_server_name       = "woitzik.dev"
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
#
# 2026-08-14: this record was fully absent from live DNS (confirmed via the
# Cloudflare API directly), not merely CNAMEd to the dead home.woitzik.dev
# DDNS chain as the previous version of this comment/resource assumed -- the
# import that was meant to bring it under Terraform referenced a record ID
# that no longer exists (see imports.tf), so it was never actually applied.
# Net effect either way was the same: Authelia itself was unreachable from
# outside the LAN, which breaks every other CrowdSec+Authelia-protected
# hostname's external access along with it. Declared here as a fresh proxied
# tunnel CNAME (routed through Traefik -> auth-final IngressRoute, same as
# everything else now that the wildcard ingress rule above exists) instead of
# riding the DDNS chain.
resource "cloudflare_dns_record" "auth" {
  zone_id = var.zone_id
  name    = "auth"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Authelia SSO -- gates almost every other exposed service"
}

# home.woitzik.dev -- Homepage dashboard, the front door and the operator's
# single loudest Phase 6 complaint ("services deployed but URLs don't work").
#
# 2026-08-14: this record was live but dead -- a non-proxied CNAME to a
# dynamic-DNS hostname (ec190fe6b6ab.sn.mynetname.net) from before the
# Cloudflare Tunnel existed, bypassing the tunnel/CrowdSec/Authelia entirely
# and pointing at a WAN IP nothing currently answers on. Repointed at the
# tunnel like everything else; Traefik's home-final IngressRoute (crowdsec-
# bouncer + authelia -> homepage:80) now actually receives the traffic.
resource "cloudflare_dns_record" "tunnel_home" {
  zone_id = var.zone_id
  name    = "home"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Homepage dashboard -- routed via Cloudflare tunnel"
}

# Wildcard catch-all for every other *.woitzik.dev hostname (home-assistant,
# status, gitea, nextcloud, claude, ~40 more) that has an IngressRoute in the
# cluster but never had its own DNS record. Pairs with the wildcard ingress
# rule in the tunnel config above -- Traefik does the actual per-host routing
# and auth from here. An exact-match record (auth/home/photos/atlantis/media
# above, or any future one) always takes precedence over this wildcard, so
# adding a hostname's own record later to give it different tunnel behavior
# is non-breaking.
resource "cloudflare_dns_record" "tunnel_wildcard" {
  zone_id = var.zone_id
  name    = "*"
  type    = "CNAME"
  content = local.tunnel_cname
  proxied = true
  ttl     = 1
  comment = "Wildcard -- catches every woitzik.dev host not given its own record, routed to Traefik"
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

# cobblemon.woitzik.dev -- previously tracked here as a stale record pending
# deletion (see git history for the original comment/import). 2026-08-14:
# confirmed via the Cloudflare API that it no longer exists live -- already
# deleted out-of-band since that note was written. Dropped from Terraform
# entirely rather than recreating a record whose own history said to remove
# it.
