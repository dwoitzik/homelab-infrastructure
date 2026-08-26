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
#
# Deliberately NOT using `import {}` blocks here (unlike everything else in
# this file): the terraform-routeros provider (1.99.1, latest as of 2026-06)
# has a bug for any resource keyed by name instead of raw id (MetaId:
# PropId(Name) in their source — ip_service is one of these). The custom
# import resolver finds the right object and stores its raw `.id` (e.g.
# "*0"), but the resource's normal Read always re-queries by name using
# whatever is in that id field — so post-import it searches for a service
# literally named "*0" and "Cannot import non-existent remote object"s.
# These 4 services can't be freshly created either (RouterOS ships exactly
# one slot per service name), so the safe path is to apply them as plain
# resources: their own create function does `d.SetId(numbers)` (the name,
# e.g. "telnet") and PATCHes the existing built-in service rather than
# creating a new one — which sidesteps the bug entirely and lands on
# the same correct end state.

resource "routeros_ip_service" "telnet" {
  numbers  = "telnet"
  port     = 23
  disabled = true
}

resource "routeros_ip_service" "ftp" {
  numbers  = "ftp"
  port     = 21
  disabled = true
}

resource "routeros_ip_service" "api" {
  numbers = "api"
  port    = 8728
  address = "10.0.0.0/8"
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
  to = routeros_ip_firewall_filter.fwd_mgmt_internet
  id = "*5E"
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
# Generated 2026-06-23 while rebuilding network/terraform.tfstate (GIT-007).
# Matched against live router REST API state. See docs/AUDIT.md GIT-007 for context.

# --- Bridge & ports ---
import {
  to = routeros_interface_bridge.core_bridge
  id = "*B"
}
import {
  to = routeros_interface_bridge_port.mgmt_port
  id = "*1"
}
import {
  to = routeros_interface_bridge_port.proxmox_port
  id = "*4"
}
import {
  to = routeros_interface_bridge_port.rpi_ports["ether6"]
  id = "*2"
}
import {
  to = routeros_interface_bridge_port.rpi_ports["ether7"]
  id = "*3"
}

# --- VLAN interfaces ---
import {
  to = routeros_interface_vlan.vlan10_mgmt
  id = "*C"
}
import {
  to = routeros_interface_vlan.vlans["vlan20-srv"]
  id = "*E"
}
import {
  to = routeros_interface_vlan.vlans["vlan30-dmz"]
  id = "*D"
}
import {
  to = routeros_interface_vlan.vlans["vlan40-iot"]
  id = "*10"
}
import {
  to = routeros_interface_vlan.vlans["vlan100-admin"]
  id = "*F"
}

# --- IP addresses ---
import {
  to = routeros_ip_address.vlan10_ip
  id = "*4"
}
import {
  to = routeros_ip_address.vlan_ips["vlan40-iot"]
  id = "*5"
}
import {
  to = routeros_ip_address.vlan_ips["vlan30-dmz"]
  id = "*6"
}
import {
  to = routeros_ip_address.vlan_ips["vlan20-srv"]
  id = "*7"
}
import {
  to = routeros_ip_address.vlan_ips["vlan100-admin"]
  id = "*8"
}

# --- Bridge VLAN matrix ---
import {
  to = routeros_interface_bridge_vlan.vlan10
  id = "*10"
}
import {
  to = routeros_interface_bridge_vlan.vlan_matrix["vlan20-srv"]
  id = "*12"
}
import {
  to = routeros_interface_bridge_vlan.vlan_matrix["vlan30-dmz"]
  id = "*6"
}
import {
  to = routeros_interface_bridge_vlan.vlan_matrix["vlan40-iot"]
  id = "*8"
}
import {
  to = routeros_interface_bridge_vlan.vlan_matrix["vlan100-admin"]
  id = "*A"
}

# --- DHCP pools ---
import {
  to = routeros_ip_pool.vlan10_pool
  id = "*5"
}
import {
  to = routeros_ip_pool.vlan_pools["vlan20-srv"]
  id = "*4"
}
import {
  to = routeros_ip_pool.vlan_pools["vlan30-dmz"]
  id = "*1"
}
import {
  to = routeros_ip_pool.vlan_pools["vlan40-iot"]
  id = "*2"
}
import {
  to = routeros_ip_pool.vlan_pools["vlan100-admin"]
  id = "*3"
}

# --- DHCP server networks ---
import {
  to = routeros_ip_dhcp_server_network.vlan10_network
  id = "*5"
}
import {
  to = routeros_ip_dhcp_server_network.vlan_networks["vlan20-srv"]
  id = "*2"
}
import {
  to = routeros_ip_dhcp_server_network.vlan_networks["vlan30-dmz"]
  id = "*3"
}
import {
  to = routeros_ip_dhcp_server_network.vlan_networks["vlan40-iot"]
  id = "*4"
}
import {
  to = routeros_ip_dhcp_server_network.vlan_networks["vlan100-admin"]
  id = "*1"
}

# --- DHCP servers ---
import {
  to = routeros_ip_dhcp_server.vlan10_dhcp
  id = "*5"
}
import {
  to = routeros_ip_dhcp_server.vlan_dhcp["vlan20-srv"]
  id = "*4"
}
import {
  to = routeros_ip_dhcp_server.vlan_dhcp["vlan30-dmz"]
  id = "*2"
}
import {
  to = routeros_ip_dhcp_server.vlan_dhcp["vlan40-iot"]
  id = "*1"
}
import {
  to = routeros_ip_dhcp_server.vlan_dhcp["vlan100-admin"]
  id = "*3"
}

# --- DHCP static leases ---
import {
  to = routeros_ip_dhcp_server_lease.server_nodes["ct-srv-docker-01"]
  id = "*10"
}
import {
  to = routeros_ip_dhcp_server_lease.server_nodes["rpi-srv-02"]
  id = "*11"
}
import {
  to = routeros_ip_dhcp_server_lease.server_nodes["rpi-srv-01"]
  id = "*12"
}
import {
  to = routeros_ip_dhcp_server_lease.mgmt_nodes["ct-mgmt-pbs-01"]
  id = "*16"
}

# --- Firewall address lists ---
import {
  to = routeros_ip_firewall_addr_list.mgmt_devices
  id = "*C"
}
import {
  to = routeros_ip_firewall_addr_list.mgmt_admin
  id = "*7"
}
import {
  to = routeros_ip_firewall_addr_list.internal_networks["vlan20-srv"]
  id = "*B"
}
import {
  to = routeros_ip_firewall_addr_list.internal_networks["vlan30-dmz"]
  id = "*9"
}
import {
  to = routeros_ip_firewall_addr_list.internal_networks["vlan40-iot"]
  id = "*A"
}
import {
  to = routeros_ip_firewall_addr_list.internal_networks["vlan100-admin"]
  id = "*8"
}

# --- Mangle / NAT ---
# GIT-008: mss_clamp had a live duplicate (*1 and *5, byte-identical config).
# *5 was imported as mss_clamp_duplicate (PR #279) then removed via a real
# terraform destroy (firewall_deterministic.tf) -- the import block for it is
# gone now that the resource itself no longer exists in config.
import {
  to = routeros_ip_firewall_mangle.mss_clamp
  id = "*1"
}
import {
  to = routeros_ip_firewall_nat.srcnat_masquerade_wan
  id = "*5"
}
import {
  to = routeros_ip_firewall_nat.srcnat_masquerade_mgmt_to_srv
  id = "*8"
}

# --- Firewall filters: anchors & deterministic chain (firewall_deterministic.tf) ---
import {
  to = routeros_ip_firewall_filter.drop_all_input
  id = "*12"
}
import {
  to = routeros_ip_firewall_filter.fwd_99_drop_all
  id = "*11"
}
import {
  to = routeros_ip_firewall_filter.in_00_antispoofing
  id = "*AC"
}
import {
  to = routeros_ip_firewall_filter.in_00a_brute_detect
  id = "*AA"
}
import {
  to = routeros_ip_firewall_filter.in_00b_brute_drop
  id = "*A8"
}
import {
  to = routeros_ip_firewall_filter.in_01_established
  id = "*5B"
}
import {
  to = routeros_ip_firewall_filter.in_01a_icmp
  id = "*A4"
}
import {
  to = routeros_ip_firewall_filter.in_02a_srv_monitoring
  id = "*74"
}
import {
  to = routeros_ip_firewall_filter.in_02_mgmt
  id = "*81"
}
import {
  to = routeros_ip_firewall_filter.fwd_00b_antispoofing
  id = "*B4"
}
import {
  to = routeros_ip_firewall_filter.fwd_00_fasttrack
  id = "*5C"
}
import {
  to = routeros_ip_firewall_filter.fwd_01_established
  id = "*61"
}
import {
  to = routeros_ip_firewall_filter.fwd_01a_icmp
  id = "*B2"
}
import {
  to = routeros_ip_firewall_filter.fwd_02_drop_invalid
  id = "*5F"
}
import {
  to = routeros_ip_firewall_filter.fwd_03_admin_any
  id = "*60"
}
import {
  to = routeros_ip_firewall_filter.fwd_04_proxy_to_mgmt
  id = "*5D"
}
import {
  to = routeros_ip_firewall_filter.fwd_04a_srv_monitoring
  id = "*AD"
}
import {
  to = routeros_ip_firewall_filter.fwd_08_allow_dns
  id = "*AB"
}
import {
  to = routeros_ip_firewall_filter.fwd_08b_allow_dns_tcp
  id = "*A9"
}
import {
  to = routeros_ip_firewall_filter.fwd_09_dmz_to_backends
  id = "*78"
}
import {
  to = routeros_ip_firewall_filter.fwd_10_srv_to_wan
  id = "*62"
}
import {
  to = routeros_ip_firewall_filter.fwd_11_dmz_to_wan
  id = "*76"
}

# --- IPv6 ---
import {
  to = routeros_ipv6_address.vlan_ula["vlan10-mgmt"]
  id = "*2C"
}
import {
  to = routeros_ipv6_address.vlan_ula["vlan20-srv"]
  id = "*2D"
}
import {
  to = routeros_ipv6_address.vlan_ula["vlan30-dmz"]
  id = "*2F"
}
import {
  to = routeros_ipv6_address.vlan_ula["vlan40-iot"]
  id = "*2E"
}
import {
  to = routeros_ipv6_address.vlan_ula["vlan100-admin"]
  id = "*30"
}
import {
  to = routeros_ipv6_firewall_nat.nat66_masquerade
  id = "*1"
}
import {
  to = routeros_ipv6_settings.global
  id = "*0"
}
import {
  to = routeros_ipv6_firewall_filter.v6_in_00_established
  id = "*7"
}
import {
  to = routeros_ipv6_firewall_filter.v6_in_01_icmpv6
  id = "*5"
}
import {
  to = routeros_ipv6_firewall_filter.v6_input_drop_all
  id = "*3"
}
import {
  to = routeros_ipv6_firewall_filter.v6_fwd_00_established
  id = "*9"
}
import {
  to = routeros_ipv6_firewall_filter.v6_fwd_01_icmpv6
  id = "*8"
}
import {
  to = routeros_ipv6_firewall_filter.v6_fwd_02_internal_out
  id = "*6"
}
import {
  to = routeros_ipv6_firewall_filter.v6_forward_drop_all
  id = "*4"
}

# --- WAN / cloud / NTP ---
import {
  to = routeros_ip_dhcp_client.wan_client
  id = "*1"
}
import {
  to = routeros_ip_cloud.ddns
  id = "*0"
}
import {
  to = routeros_system_ntp_client.ntp
  id = "*0"
}

# --- SNMP ---
import {
  to = routeros_snmp_community.monitoring
  id = "*1"
}
import {
  to = routeros_snmp_community.prometheus_default
  id = "*0"
}
import {
  to = routeros_snmp.settings
  id = "*0"
}

# --- Scheduler / scripts ---
# night_mode/day_mode/leds_on/leds_off import blocks removed 2026-08-26 along
# with their resource blocks in main.tf -- see that file's LED section. These
# targeted the same live objects (night_mode_leds/day_mode_leds, *0/*1) that
# power.tf's own led_off_night/led_on_day resources already own; importing
# both would have left two Terraform resource addresses fighting over the
# same live scheduler on every subsequent plan.
import {
  to = routeros_system_scheduler.disable_unused_ports
  id = "*2"
}
# Trigger fresh atlantis plan (GIT-009 apply pending)
