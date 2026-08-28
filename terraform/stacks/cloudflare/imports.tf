# These 2 DNS records already existed live (created via Cloudflare dashboard,
# never Terraform-managed) -- import instead of destroy+recreate to avoid any
# DNS blip on live traffic.
#
# mc_playit is the one that actually changes content on import: it currently
# points to home.woitzik.dev (the old direct-WAN-port-forward setup), not yet
# cut over to the playit.gg tunnel hostname this resource declares -- review
# that specific diff before applying.
import {
  to = cloudflare_dns_record.tunnel_photos
  id = "1f15ed0f3a8b497302ba339dcab3c060/fdd4ba6725861fc96dce48e5769e7aaa"
}
import {
  to = cloudflare_dns_record.mc_playit[0]
  id = "1f15ed0f3a8b497302ba339dcab3c060/0a20f0e459e5fb34169ff5d4dda9e8c2"
}

# 2026-08-14 (ADR-033): tunnel_atlantis and tunnel_home import blocks removed
# from here -- both records are being dropped entirely per the operator's
# public-exposure-allowlist decision (see main.tf), not imported/kept. No
# import needed for a resource that's being removed from config, only for one
# being newly brought under management.

# 2026-08-14 23:09 UTC: this PR's own `atlantis apply -p cloudflare` partially
# failed on this exact class of issue -- cloudflare_dns_record.tunnel_headscale
# already existed live (created out-of-band, same as photos/mc_playit above)
# and the plan tried to create it fresh instead of importing, hitting
# Cloudflare's "record already exists" 400. Everything else in that apply
# succeeded first (wildcard/atlantis/auth/home/media DNS records destroyed,
# tunnel ingress config updated to the photos+headscale allowlist) -- confirmed
# live via the Cloudflare API directly: headscale.woitzik.dev was already
# serving 200 through the correct tunnel config the whole time, no outage,
# just Terraform's own state not yet tracking this one resource.
# 2026-08-28: retargeted to dns_headscale_dmz (see main.tf's moved block) --
# same record, same id, renamed when the record moved off the tunnel.
import {
  to = cloudflare_dns_record.dns_headscale_dmz
  id = "1f15ed0f3a8b497302ba339dcab3c060/6a324d0a219b681417f63b08503f87c1"
}

# The claude-agent dedicated tunnel (ADR-032, PR #437) was destroyed by that
# same apply -- expected and correct, not a bug: claude.woitzik.dev was never
# on the 2-host public allowlist this PR establishes, confirmed by the
# operator directly (2026-08-15, Phase 8 brief). This agent remains reachable
# via Tailscale/LAN, which was always the primary access path regardless.
