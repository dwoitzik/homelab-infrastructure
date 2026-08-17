variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API token with Zone:DNS:Edit + Cloudflare Tunnel:Edit permissions"
  sensitive   = true
}

variable "zone_id" {
  type        = string
  description = "Cloudflare Zone ID for woitzik.dev"
  default     = "1f15ed0f3a8b497302ba339dcab3c060"
}

variable "account_id" {
  type        = string
  description = "Cloudflare Account ID"
  default     = "61863ddb47e05bc833c7671f69e3454c"
}

variable "tunnel_id" {
  type        = string
  description = "Cloudflare Tunnel ID (from cloudflared token)"
  default     = "1f2e0f78-214b-4f59-881d-37e22625ae6e"
}

variable "mc_playit_hostname" {
  type        = string
  description = "playit.gg tunnel hostname for mc.woitzik.dev CNAME."
  default     = "doing-sigma.gl.joinmc.link"
}

variable "immich_access_family_emails" {
  type        = list(string)
  description = <<-EOT
    Email addresses allowed through the Cloudflare Access One-time-PIN gate in
    front of photos.woitzik.dev. Defaults to just the operator's own address
    (already public elsewhere in this repo, e.g. Firefly III's SITE_OWNER) --
    add the rest of the family's addresses via terraform.tfvars (not
    committed) rather than hardcoding other people's emails into a public repo.
  EOT
  default     = ["david@woitzik.dev"]
}
