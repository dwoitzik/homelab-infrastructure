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
  pvid      = 10
  comment   = "Management Access Port"
}

resource "routeros_interface_bridge_port" "proxmox_port" {
  bridge    = routeros_interface_bridge.core_bridge.name
  interface = local.proxmox_port
  pvid      = 1
  comment   = "Proxmox Trunk"
}

resource "routeros_interface_bridge_port" "rpi_ports" {
  for_each  = local.rpi_port_mapping
  bridge    = routeros_interface_bridge.core_bridge.name
  interface = each.key
  pvid      = each.value
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

# Matrix for VLAN 10 (Manual)
resource "routeros_interface_bridge_vlan" "vlan10" {
  bridge   = routeros_interface_bridge.core_bridge.name
  vlan_ids = [10]
  tagged   = [routeros_interface_bridge.core_bridge.name]
  untagged = ["ether2"]
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

  untagged = [
    for port, vlan in local.rpi_port_mapping : port if vlan == each.value
  ]
}

###############################################################################
# Static DHCP Leases for Raspberry Pi Cluster
###############################################################################

resource "routeros_ip_dhcp_server_lease" "rpi_nodes" {
  for_each = {
    "rpi-srv-01" = { mac = "D8:3A:DD:1D:9A:70", ip = "10.0.20.2" }
    "rpi-srv-02" = { mac = "D8:3A:DD:27:9E:98", ip = "10.0.20.3" }
  }

  address     = each.value.ip
  mac_address = each.value.mac
  server      = "dhcp-vlan20-srv"
  comment     = "Static lease for ${each.key}"
}
