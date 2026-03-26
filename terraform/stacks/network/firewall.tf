# ===============================================
# ANCHOR RULES
# ===============================================

resource "routeros_ip_firewall_filter" "drop_all_input" {
  action  = "drop"
  chain   = "input"
  comment = "INPUT: Default drop"
}

resource "routeros_ip_firewall_filter" "fwd_99_drop_all" {
  action     = "drop"
  chain      = "forward"
  log        = true
  log_prefix = "FW_DROP"
  comment    = "99: Global - Final Drop (Zero Trust Policy)"
}

resource "routeros_ip_firewall_mangle" "mss_clamp" {
  chain              = "forward"
  action             = "change-mss"
  new_mss            = "clamp-to-pmtu"
  out_interface      = "ether1"
  protocol           = "tcp"
  tcp_flags          = "syn"
  comment            = "TCP MSS clamping for MTU efficiency"
}

# ===============================================
# INPUT CHAIN (Traffic TO the Router)
# ===============================================

resource "routeros_ip_firewall_filter" "in_01_established" {
  action           = "accept"
  chain            = "input"
  connection_state = "established,related,untracked"
  place_before     = routeros_ip_firewall_filter.in_02_mgmt.id
  comment          = "IN-01: Allow established/related"
}

resource "routeros_ip_firewall_filter" "in_02_mgmt" {
  action           = "accept"
  chain            = "input"
  src_address_list = "Mgmt_Devices"
  place_before     = routeros_ip_firewall_filter.in_03_wg.id
  comment          = "IN-02: Allow Admin-VLAN access to Router-API"
}

resource "routeros_ip_firewall_filter" "in_03_wg" {
  action       = "accept"
  chain        = "input"
  protocol     = "udp"
  dst_port     = local.vpn_config.port
  in_interface = "ether1"
  place_before = routeros_ip_firewall_filter.drop_all_input.id
  comment      = "IN-03: WireGuard handshake"
}

# ===============================================
# FORWARD CHAIN (Traffic THROUGH the Router)
# ===============================================

resource "routeros_ip_firewall_filter" "fwd_00_fasttrack" {
  action           = "fasttrack-connection"
  chain            = "forward"
  connection_state = "established,related"
  hw_offload       = true
  place_before     = routeros_ip_firewall_filter.fwd_01_established.id
  comment          = "00: Global - Fasttrack for CPU efficiency"
}

resource "routeros_ip_firewall_filter" "fwd_01_established" {
  action           = "accept"
  chain            = "forward"
  connection_state = "established,related,untracked"
  place_before     = routeros_ip_firewall_filter.fwd_02_drop_invalid.id
  comment          = "01: Global - Allow established/related"
}

resource "routeros_ip_firewall_filter" "fwd_02_drop_invalid" {
  action           = "drop"
  chain            = "forward"
  connection_state = "invalid"
  place_before     = routeros_ip_firewall_filter.fwd_03_admin_any.id
  comment          = "02: Global - Drop invalid packets"
}

resource "routeros_ip_firewall_filter" "fwd_03_admin_any" {
  action       = "accept"
  chain        = "forward"
  src_address  = "10.0.100.0/24"
  place_before = routeros_ip_firewall_filter.fwd_04_vpn_laptop.id
  comment      = "03: Admin - Full access to all internal VLANs"
}

resource "routeros_ip_firewall_filter" "fwd_04_vpn_laptop" {
  action       = "accept"
  chain        = "forward"
  src_address  = local.vpn_laptop_ip
  dst_address  = "10.0.0.0/16"
  place_before = routeros_ip_firewall_filter.fwd_05_vpn_handy.id
  comment      = "04: VPN - Laptop Full Access"
}

resource "routeros_ip_firewall_filter" "fwd_05_vpn_handy" {
  action       = "accept"
  chain        = "forward"
  src_address  = local.vpn_handy_ip
  dst_address  = "10.0.20.0/24"
  place_before = routeros_ip_firewall_filter.fwd_06_allow_dns.id
  comment      = "05: VPN - Handy limited to services"
}

resource "routeros_ip_firewall_filter" "fwd_06_allow_dns" {
  action       = "accept"
  chain        = "forward"
  dst_address  = "10.0.20.5"
  dst_port     = "53"
  protocol     = "udp"
  place_before = routeros_ip_firewall_filter.fwd_07_dmz_to_wan.id
  comment      = "06: DNS - Allow internal DNS queries to AdGuard"
}

resource "routeros_ip_firewall_filter" "fwd_07_dmz_to_wan" {
  action        = "accept"
  chain         = "forward"
  src_address   = "10.0.30.0/24"
  out_interface = "ether1"
  place_before  = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment       = "07: DMZ - Internet access only"
}
