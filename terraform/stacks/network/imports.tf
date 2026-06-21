###############################################################################
# Pre-existing RouterOS objects adopted into Terraform via native `import`
# blocks (Terraform >= 1.5). These are fixed system services that cannot be
# freshly created — only imported and then managed going forward.
###############################################################################

# --- Service hardening (2026-06-21 audit) ---
# Found via a read-only REST API audit: telnet/ftp enabled (both unencrypted,
# no legitimate use here), and api-ssl allowed from 0.0.0.0/0 (no WAN
# port-forward exists for it today, but the service-level ACL was wide open
# regardless). Restricting api/api-ssl to 10.0.0.0/8 covers every VLAN in the
# homelab (so Atlantis/Terraform's own API access keeps working regardless of
# which internal host it runs from) while blocking anything outside it.

import {
  to = routeros_ip_service.telnet
  id = "*0"
}

resource "routeros_ip_service" "telnet" {
  numbers  = "telnet"
  port     = 23
  disabled = true
}

import {
  to = routeros_ip_service.ftp
  id = "*1"
}

resource "routeros_ip_service" "ftp" {
  numbers  = "ftp"
  port     = 21
  disabled = true
}

import {
  to = routeros_ip_service.api
  id = "*7"
}

resource "routeros_ip_service" "api" {
  numbers = "api"
  port    = 8728
  address = "10.0.0.0/8"
}

import {
  to = routeros_ip_service.api_ssl
  id = "*9"
}

resource "routeros_ip_service" "api_ssl" {
  numbers = "api-ssl"
  port    = 8729
  address = "10.0.0.0/8"
}
