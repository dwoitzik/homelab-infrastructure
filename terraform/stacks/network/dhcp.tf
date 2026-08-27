###############################################################################
# DHCP Configuration
###############################################################################

# --- Homelab Pools & Servers ---

resource "routeros_ip_pool" "vlan_pools" {
  for_each = local.homelab_vlans
  name     = "pool-${each.key}"
  ranges   = ["10.0.${each.value}.10-10.0.${each.value}.254"]
}

# CORRECTED 2026-07-10 (was wrong): this was originally written believing
# RouterOS's own DHCP server was handing out "home.lan" as the DHCP
# domain-search suffix. Root-caused properly: the live router genuinely has
# no domain/search config anywhere in `/ip dhcp-server`, `/ip dhcp-server
# network`, or `/ip dns` (confirmed via the REST API, all absent, not just
# empty) -- DHCP was never the source, which is exactly why this resource's
# plan always showed zero diff against live state. The real source is
# Proxmox's own cloud-init generator falling back to the PVE node's
# configured search domain (`pvesh get /nodes/.../dns` -> home.lan) when a
# VM's `initialization.dns.domain` is left unset -- see
# terraform/stacks/proxmox/vm.tf's k3s VM comments for the actual fix.
# `domain = ""` is left declared here since it's harmless and correctly
# matches live reality, not because this resource is the fix.
resource "routeros_ip_dhcp_server_network" "vlan_networks" {
  for_each   = local.homelab_vlans
  address    = "10.0.${each.value}.0/24"
  gateway    = "10.0.${each.value}.1"
  dns_server = ["10.0.20.5"]
  domain     = ""
  comment    = "Network for ${each.key}"
}

resource "routeros_ip_dhcp_server" "vlan_dhcp" {
  for_each     = local.homelab_vlans
  interface    = routeros_interface_vlan.vlans[each.key].name
  name         = "dhcp-${each.key}"
  address_pool = routeros_ip_pool.vlan_pools[each.key].name
  disabled     = false
  # Declared explicitly (ADR-027 pass, ground-truthed via a real live plan,
  # not guessed): RouterOS rejects clearing this field entirely ("at least
  # one dynamic lease identifier should be specified", a genuine live 400
  # confirmed by a real failed apply attempt) -- the provider was silently
  # planning to null it because nothing here declared it, not because the
  # live value was ever actually different.
  dynamic_lease_identifiers = "client-mac,client-id"
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
  domain     = ""
}

resource "routeros_ip_dhcp_server" "vlan10_dhcp" {
  interface    = routeros_interface_vlan.vlan10_mgmt.name
  name         = "dhcp-vlan10"
  address_pool = routeros_ip_pool.vlan10_pool.name
  disabled     = false
  # See vlan_dhcp's identical comment above -- same real, live-confirmed fix.
  dynamic_lease_identifiers = "client-mac,client-id"
}
