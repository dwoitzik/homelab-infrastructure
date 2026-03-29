# ===============================================
# ANCHOR RULES & MANGLE
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
  chain         = "forward"
  action        = "change-mss"
  new_mss       = "clamp-to-pmtu"
  out_interface = "ether1"
  protocol      = "tcp"
  tcp_flags     = "syn"
  comment       = "TCP MSS clamping for MTU efficiency"
}

# ===============================================
# INPUT CHAIN (Traffic TO the Router)
# ===============================================

resource "routeros_ip_firewall_filter" "in_05_snmp" {
  action       = "accept"
  chain        = "input"
  src_address  = "10.0.20.0/24"
  protocol     = "udp"
  dst_port     = "161"
  place_before = routeros_ip_firewall_filter.drop_all_input.id
  comment      = "IN-05: Allow SNMP from SRV-Net (Monitoring)"
}

resource "routeros_ip_firewall_filter" "in_04_mikrodash" {
  action       = "accept"
  chain        = "input"
  src_address  = "10.0.20.252"
  protocol     = "tcp"
  dst_port     = "8728,8729"
  place_before = routeros_ip_firewall_filter.in_05_snmp.id
  comment      = "IN-04: Allow MikroDash API access from Docker LXC"
}

resource "routeros_ip_firewall_filter" "in_03_wg" {
  action       = "accept"
  chain        = "input"
  protocol     = "udp"
  dst_port     = local.vpn_config.port
  in_interface = "ether1"
  place_before = routeros_ip_firewall_filter.in_04_mikrodash.id
  comment      = "IN-03: WireGuard handshake"
}

resource "routeros_ip_firewall_filter" "in_02_mgmt" {
  action           = "accept"
  chain            = "input"
  src_address_list = "Mgmt_Devices"
  place_before     = routeros_ip_firewall_filter.in_03_wg.id
  comment          = "IN-02: Allow Admin-VLAN access to Router-API"
}

resource "routeros_ip_firewall_filter" "in_01_established" {
  action           = "accept"
  chain            = "input"
  connection_state = "established,related,untracked"
  place_before     = routeros_ip_firewall_filter.in_02_mgmt.id
  comment          = "IN-01: Allow established/related"
}

# ===============================================
# FORWARD CHAIN (Traffic THROUGH the Router)
# ===============================================

resource "routeros_ip_firewall_filter" "fwd_13_fb_wlan_to_proxy" {
  action       = "accept"
  chain        = "forward"
  src_address  = "192.168.178.0/24"
  dst_address  = "10.0.20.5"
  dst_port     = "80,443"
  protocol     = "tcp"
  in_interface = "ether1"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "13: WAN - Allow Fritzbox WLAN access to internal Proxy"
}

resource "routeros_ip_firewall_filter" "fwd_12_dmz_to_wan" {
  action        = "accept"
  chain         = "forward"
  src_address   = "10.0.30.0/24"
  out_interface = "ether1"
  place_before  = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment       = "12: DMZ - Internet access only"
}

resource "routeros_ip_firewall_filter" "fwd_11_mgmt_to_wan" {
  action        = "accept"
  chain         = "forward"
  src_address   = "10.0.10.0/24"
  out_interface = "ether1"
  place_before  = routeros_ip_firewall_filter.fwd_12_dmz_to_wan.id
  comment       = "11: MGMT - Internet access (Critical for PBS rclone & Updates)"
}

resource "routeros_ip_firewall_filter" "fwd_10_srv_to_wan" {
  action        = "accept"
  chain         = "forward"
  src_address   = "10.0.20.0/24"
  out_interface = "ether1"
  place_before  = routeros_ip_firewall_filter.fwd_11_mgmt_to_wan.id
  comment       = "10: SRV - Internet access (Critical for Unbound DNS)"
}

resource "routeros_ip_firewall_filter" "fwd_09_dmz_to_backends" {
  chain            = "forward"
  action           = "accept"
  src_address      = "10.0.30.0/24"
  dst_address_list = "Reverse_Proxy_Targets"
  dst_port         = "80,443,8006,8007"
  protocol         = "tcp"
  place_before     = routeros_ip_firewall_filter.fwd_10_srv_to_wan.id
  comment          = "09: DMZ - Access to specific Reverse Proxy Backends"
}

resource "routeros_ip_firewall_filter" "fwd_08_allow_dns" {
  action       = "accept"
  chain        = "forward"
  dst_address  = "10.0.20.5"
  dst_port     = "53"
  protocol     = "udp"
  place_before = routeros_ip_firewall_filter.fwd_09_dmz_to_backends.id
  comment      = "08: DNS - Allow internal DNS queries to AdGuard VIP"
}

resource "routeros_ip_firewall_filter" "fwd_07_vpn_handy_dmz" {
  action       = "accept"
  chain        = "forward"
  src_address  = local.vpn_handy_ip
  dst_address  = "10.0.30.0/24"
  place_before = routeros_ip_firewall_filter.fwd_08_allow_dns.id
  comment      = "07: VPN - Mobile access to DMZ (External Proxy)"
  lifecycle {
    ignore_changes = [src_address]
  }
}

resource "routeros_ip_firewall_filter" "fwd_06_vpn_handy_srv" {
  action       = "accept"
  chain        = "forward"
  src_address  = local.vpn_handy_ip
  dst_address  = "10.0.20.0/24"
  place_before = routeros_ip_firewall_filter.fwd_07_vpn_handy_dmz.id
  comment      = "06: VPN - Mobile limited to internal services"
  lifecycle {
    ignore_changes = [src_address]
  }
}

resource "routeros_ip_firewall_filter" "fwd_05_vpn_laptop" {
  action       = "accept"
  chain        = "forward"
  src_address  = local.vpn_laptop_ip
  dst_address  = "10.0.0.0/16"
  place_before = routeros_ip_firewall_filter.fwd_06_vpn_handy_srv.id
  comment      = "05: VPN - Laptop Full Access"
  lifecycle {
    ignore_changes = [src_address]
  }
}

resource "routeros_ip_firewall_filter" "fwd_04_proxy_to_mgmt" {
  chain        = "forward"
  action       = "accept"
  src_address  = "10.0.20.0/24"
  dst_address  = "10.0.10.0/24"
  dst_port     = "8006,8007"
  protocol     = "tcp"
  place_before = routeros_ip_firewall_filter.fwd_05_vpn_laptop.id
  comment      = "04: SRV - Internal Proxy access to MGMT Web GUIs"
}

resource "routeros_ip_firewall_filter" "fwd_03_admin_any" {
  action       = "accept"
  chain        = "forward"
  src_address  = "10.0.100.0/24"
  place_before = routeros_ip_firewall_filter.fwd_04_proxy_to_mgmt.id
  comment      = "03: Admin - Full access to all internal VLANs"
}

resource "routeros_ip_firewall_filter" "fwd_02_drop_invalid" {
  action           = "drop"
  chain            = "forward"
  connection_state = "invalid"
  place_before     = routeros_ip_firewall_filter.fwd_03_admin_any.id
  comment          = "02: Global - Drop invalid packets"
}

resource "routeros_ip_firewall_filter" "fwd_01_established" {
  action           = "accept"
  chain            = "forward"
  connection_state = "established,related,untracked"
  place_before     = routeros_ip_firewall_filter.fwd_02_drop_invalid.id
  comment          = "01: Global - Allow established/related"
}

resource "routeros_ip_firewall_filter" "fwd_00_fasttrack" {
  action           = "fasttrack-connection"
  chain            = "forward"
  connection_state = "established,related"
  hw_offload       = true
  place_before     = routeros_ip_firewall_filter.fwd_01_established.id
  comment          = "00: Global - Fasttrack for CPU efficiency"
}
