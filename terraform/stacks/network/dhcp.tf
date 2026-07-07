###############################################################################
# DHCP Configuration
###############################################################################

# --- Homelab Pools & Servers ---

resource "routeros_ip_pool" "vlan_pools" {
  for_each = local.homelab_vlans
  name     = "pool-${each.key}"
  ranges   = ["10.0.${each.value}.10-10.0.${each.value}.254"]
}

# domain explicitly set to "" -- these networks were live-confirmed handing out
# "home.lan" as the DHCP domain-search suffix (via networkctl status on a k3s VM),
# but this attribute was never declared in this resource at all, and the last
# terraform.tfstate.backup on disk shows domain=null for every network. That's
# drift: someone set it manually via Winbox at some point, bypassing Terraform
# (against CLAUDE.local.md's "never make manual RouterOS changes" rule), or an
# earlier Terraform apply set it and this state backup predates it. Either way,
# every pod in the k3s cluster inherits this via kubelet's DNS policy (which
# appends the node's own search domain to every pod's resolv.conf), causing a
# needless recursive DNS lookup for "*.home.lan" on top of every external name
# resolution attempt (ndots:5 default). unbound has no authoritative answer for
# home.lan (unlike fritz.box, which has a real stub-zone), so every one of these
# recurses all the way out and fails -- confirmed ~341ms average vs. instant for
# a local answer. Declaring domain = "" here forces Terraform to detect and
# correct this drift on the next Atlantis apply, regardless of what the live
# value actually is.
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
}
