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
    Email addresses allowed to run the Cloudflare One-time-PIN (OTP) flow and
    obtain an OIDC token for Immich. These match the "primary email addresses
    of the family Immich accounts" (operator, 2026-09-17: the current set is
    complete, no more will be added) -- the OIDC identity must match an
    existing Immich account email, or login will fail. Enforced on the
    Access SaaS application's allow policy; one entry per address.
  EOT
  # Known Immich account addresses (DB user table), matched by OIDC email
  # claim: David (admin), Adrian, Katharina.
  default = [
    "woitzikdavid18@gmail.com",
    "goraadrian28@gmail.com",
    "dwoitzik50@gmail.com",
  ]
}
