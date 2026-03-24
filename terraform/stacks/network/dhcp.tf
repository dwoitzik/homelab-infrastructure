###############################################################################
# DHCP Configuration
###############################################################################

# --- Homelab Pools & Servers ---

resource "routeros_ip_pool" "vlan_pools" {
  for_each = local.homelab_vlans
  name     = "pool-${each.key}"
  ranges   = ["10.0.${each.value}.10-10.0.${each.value}.254"]
}

resource "routeros_ip_dhcp_server_network" "vlan_networks" {
  for_each   = local.homelab_vlans
  address    = "10.0.${each.value}.0/24"
  gateway    = "10.0.${each.value}.1"
  dns_server = ["10.0.20.5"]
  comment    = "Network for ${each.key}"
}

resource "routeros_ip_dhcp_server" "vlan_dhcp" {
  for_each     = local.homelab_vlans
  interface    = routeros_interface_vlan.vlans[each.key].name
  name         = "dhcp-${each.key}"
  address_pool = routeros_ip_pool.vlan_pools[each.key].name
  disabled     = false
}

# --- Management DHCP (VLAN 10) ---

resource "routeros_ip_pool" "vlan10_pool" {
  name   = "pool-vlan10-mgmt"
  ranges = ["10.0.10.10-10.0.10.254"]
}

resource "routeros_ip_dhcp_server_network" "vlan10_network" {
  address    = "10.0.10.0/24"
  gateway    = "10.0.10.1"
  dns_server = ["10.0.20.5"]
}

resource "routeros_ip_dhcp_server" "vlan10_dhcp" {
  interface    = routeros_interface_vlan.vlan10_mgmt.name
  name         = "dhcp-vlan10"
  address_pool = routeros_ip_pool.vlan10_pool.name
  disabled     = false
}
