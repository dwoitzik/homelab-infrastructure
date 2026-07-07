# These 3 DNS records already existed live (created via Cloudflare dashboard,
# never Terraform-managed) -- tunnel_media applied cleanly as a fresh create,
# but photos/atlantis/mc hit "record already exists" (409/400) on first apply.
# Import instead of destroy+recreate to avoid any DNS blip on live traffic.
#
# mc_playit is the one that actually changes content on import: it currently
# points to home.woitzik.dev (the old direct-WAN-port-forward setup), not yet
# cut over to the playit.gg tunnel hostname this resource declares -- review
# that specific diff before applying (see IAC-002/GIT-008 in docs/AUDIT.md).
import {
  to = cloudflare_dns_record.tunnel_photos
  id = "1f15ed0f3a8b497302ba339dcab3c060/fdd4ba6725861fc96dce48e5769e7aaa"
}
import {
  to = cloudflare_dns_record.tunnel_atlantis
  id = "1f15ed0f3a8b497302ba339dcab3c060/b979079045563055f6ff21b9924e7d40"
}
import {
  to = cloudflare_dns_record.mc_playit[0]
  id = "1f15ed0f3a8b497302ba339dcab3c060/0a20f0e459e5fb34169ff5d4dda9e8c2"
}

# auth.woitzik.dev -- created 2025-11-01 via the dashboard, live values
# (content/proxied/ttl) already match what main.tf declares exactly, so
# this import is expected to show zero diff.
import {
  to = cloudflare_dns_record.auth
  id = "1f15ed0f3a8b497302ba339dcab3c060/d1bdef517767720d53f186753f71c306"
}
