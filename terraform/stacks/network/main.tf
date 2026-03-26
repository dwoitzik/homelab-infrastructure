###############################################################################
# Locals & Project Configuration
###############################################################################

locals {
  homelab_vlans = {
    "vlan20-srv"    = 20
    "vlan30-dmz"    = 30
    "vlan40-iot"    = 40
    "vlan100-admin" = 100
  }

  rpi_port_mapping = {
    "ether6" = 20 # RPi 4B #1 (Keepalived Node A)
    "ether7" = 20 # RPi 4B #2 (Keepalived Node B)
  }

  proxmox_port = "ether5"

  vpn_config = {
    subnet = "10.6.0.0/24"
    port   = 51820
    name   = "wg-roadwarrior"
  }

  vpn_handy_ip  = "10.6.0.2/32"
  vpn_laptop_ip = "10.6.0.3/32"
}

###############################################################################
# Bridge Configuration
###############################################################################

resource "routeros_interface_bridge" "core_bridge" {
  name           = "bridge1"
  vlan_filtering = true
  comment        = "Core bridge managed by Terraform"
}

# --- Bridge Ports ---

resource "routeros_interface_bridge_port" "mgmt_port" {
  bridge    = routeros_interface_bridge.core_bridge.name
  interface = "ether2"
  pvid      = 100
  hw        = true
  comment   = "Admin Workstation Access Port"
}

resource "routeros_interface_bridge_port" "proxmox_port" {
  bridge    = routeros_interface_bridge.core_bridge.name
  interface = local.proxmox_port
  pvid      = 1
  hw        = true
  comment   = "Proxmox Trunk (Tagged VLANs)"
}

resource "routeros_interface_bridge_port" "rpi_ports" {
  for_each  = local.rpi_port_mapping
  bridge    = routeros_interface_bridge.core_bridge.name
  interface = each.key
  pvid      = each.value
  hw        = true
  comment   = "Keepalived Node"
}

###############################################################################
# VLAN Interfaces & IP Addresses
###############################################################################

# --- Management (VLAN 10) ---
resource "routeros_interface_vlan" "vlan10_mgmt" {
  interface = routeros_interface_bridge.core_bridge.name
  name      = "vlan10-mgmt"
  vlan_id   = 10
}

resource "routeros_ip_firewall_addr_list" "mgmt_devices" {
  list    = "Mgmt_Devices"
  address = "10.0.100.0/24"
}

resource "routeros_ip_firewall_addr_list" "internal_networks" {
  for_each = local.homelab_vlans
  list     = "Internal_Networks"
  address  = "10.0.${each.value}.0/24"
}

resource "routeros_ip_address" "vlan10_ip" {
  address   = "10.0.10.1/24"
  interface = routeros_interface_vlan.vlan10_mgmt.name
}

# --- Homelab VLANs (20, 30, 40, 100) ---
resource "routeros_interface_vlan" "vlans" {
  for_each  = local.homelab_vlans
  interface = routeros_interface_bridge.core_bridge.name
  name      = each.key
  vlan_id   = each.value
}

resource "routeros_ip_address" "vlan_ips" {
  for_each  = local.homelab_vlans
  address   = "10.0.${each.value}.1/24"
  interface = routeros_interface_vlan.vlans[each.key].name
}

###############################################################################
# Bridge VLAN Matrix (L2 Forwarding)
###############################################################################

resource "routeros_interface_bridge_vlan" "vlan10" {
  bridge   = routeros_interface_bridge.core_bridge.name
  vlan_ids = [10]
  tagged   = [
    routeros_interface_bridge.core_bridge.name,
    local.proxmox_port
  ]
}

# Matrix for other VLANs (Loop)
resource "routeros_interface_bridge_vlan" "vlan_matrix" {
  for_each = local.homelab_vlans

  bridge   = routeros_interface_bridge.core_bridge.name
  vlan_ids = [each.value]

  tagged = [
    routeros_interface_bridge.core_bridge.name,
    local.proxmox_port
  ]

  untagged = concat(
    [for port, vlan in local.rpi_port_mapping : port if vlan == each.value],
    each.value == 100 ? ["ether2"] : []
  )
}

###############################################################################
# Static DHCP Leases
###############################################################################

resource "routeros_ip_dhcp_server_lease" "server_nodes" {
  for_each = {
    "rpi-srv-01" = { mac = "D8:3A:DD:1D:9A:70", ip = "10.0.20.2" }
    "rpi-srv-02" = { mac = "D8:3A:DD:27:9E:98", ip = "10.0.20.3" }
    "ct-srv-docker-01" = { mac = "bc:24:11:85:76:c5", ip = "10.0.20.252" }
  }

  address     = each.value.ip
  mac_address = each.value.mac
  server      = "dhcp-vlan20-srv"
  comment     = "Static lease for ${each.key}"
}

resource "routeros_ip_dhcp_server_lease" "mgmt_nodes" {
  for_each = {
    "ct-mgmt-pbs-01" = { mac = "bc:24:11:24:7a:71", ip = "10.0.10.110" }
  }

  address     = each.value.ip
  mac_address = each.value.mac
  server      = routeros_ip_dhcp_server.vlan10_dhcp.name
  comment     = "Static lease for ${each.key}"
}

###############################################################################
# LEDs
###############################################################################

resource "routeros_system_script" "leds_off" {
  name   = "leds_off"
  source = "/system leds set [find] enabled=no"
}

resource "routeros_system_script" "leds_on" {
  name   = "leds_on"
  source = "/system leds set [find] enabled=yes"
}

resource "routeros_system_scheduler" "night_mode" {
  name       = "night_mode_leds"
  start_time = "22:00:00"
  interval   = "1d"
  on_event   = "leds_off"
}

resource "routeros_system_scheduler" "day_mode" {
  name       = "day_mode_leds"
  start_time = "06:00:00"
  interval   = "1d"
  on_event   = "leds_on"
}
