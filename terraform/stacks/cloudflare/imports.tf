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

# 2026-08-14 (ADR-019): tunnel_atlantis and tunnel_home import blocks removed
# from here -- both records are being dropped entirely per the operator's
# public-exposure-allowlist decision (see main.tf), not imported/kept. No
# import needed for a resource that's being removed from config, only for one
# being newly brought under management.
