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

# --- Firewall rules that existed live but were never in Terraform (2026-06-21 audit) ---
# See firewall_extra.tf for the resource definitions and full context.

import {
  to = routeros_ip_firewall_filter.in_03_admin_router_api
  id = "*50"
}

import {
  to = routeros_ip_firewall_filter.in_06_snmp
  id = "*51"
}

import {
  to = routeros_ip_firewall_filter.in_05_k3s_router_api
  id = "*56"
}

import {
  to = routeros_ip_firewall_filter.in_04_atlantis_api
  id = "*58"
}

import {
  to = routeros_ip_firewall_filter.fwd_vpn_mobile_dmz
  id = "*4F"
}

import {
  to = routeros_ip_firewall_filter.fwd_vpn_mobile_internal
  id = "*53"
}

import {
  to = routeros_ip_firewall_filter.fwd_vpn_laptop_full
  id = "*54"
}

import {
  to = routeros_ip_firewall_filter.fwd_monitoring_dmz_scrape
  id = "*55"
}

import {
  to = routeros_ip_firewall_filter.fwd_wan_minecraft
  id = "*59"
}

import {
  to = routeros_ip_firewall_filter.fwd_mgmt_internet
  id = "*5E"
}

import {
  to = routeros_ip_firewall_filter.fwd_wan_cobblemon
  id = "*B5"
}

import {
  to = routeros_ip_firewall_filter.fwd_vpn_full_tunnel
  id = "*63"
}

import {
  to = routeros_ip_firewall_filter.fwd_proxmox_oidc
  id = "*64"
}

import {
  to = routeros_ip_firewall_filter.fwd_heimnetz_k3s_ingress
  id = "*69"
}

import {
  to = routeros_ip_firewall_filter.fwd_mgmt_oidc_traefik
  id = "*6A"
}

import {
  to = routeros_ipv6_firewall_filter.v6_block_rogue_ra
  id = "*A"
}
