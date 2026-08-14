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

# 2026-08-14: verified live against the Cloudflare API directly (Phase 6 URL
# audit) -- both of the following import IDs no longer exist (404 from the
# API), most likely lost in the same Garage/Terraform-state wipe that hit
# every other stack. Since #352's own comment already notes this project's
# state was never actually picked up by a real apply, these two imports were
# almost certainly dead well before this check. Removing rather than fixing
# the ID: `auth` is recreated fresh in main.tf pointed at the tunnel instead
# of the dead DDNS chain it used to import as, and `cobblemon_stale` is
# dropped entirely -- its own resource comment already recommended deletion,
# and it is now confirmed gone rather than merely stale.
#
# home.woitzik.dev *does* still exist live and is real dead weight (a CNAME
# to a DDNS host that no longer answers) -- imported below and repointed at
# the tunnel rather than left broken.
import {
  to = cloudflare_dns_record.tunnel_home
  id = "1f15ed0f3a8b497302ba339dcab3c060/6f0da207423ee2f356c5a0655d5bf644"
}
