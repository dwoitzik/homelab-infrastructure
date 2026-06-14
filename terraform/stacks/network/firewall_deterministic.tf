# ===============================================
# ANCHOR RULES & MANGLE
# ===============================================

resource "routeros_ip_firewall_filter" "drop_all_input" {
  action  = "drop"
  chain   = "input"
  comment = "INPUT: Default drop"
}

resource "routeros_ip_firewall_filter" "fwd_99_drop_all" {
  action  = "drop"
  chain   = "forward"
  log     = false
  comment = "99: Global - Final Drop (Zero Trust Policy)"
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

# Anti-spoofing: block RFC1918 source addresses arriving from WAN
resource "routeros_ip_firewall_filter" "in_00_antispoofing" {
  action       = "drop"
  chain        = "input"
  src_address  = "10.0.0.0/8"
  in_interface = "ether1"
  place_before = routeros_ip_firewall_filter.in_00a_brute_detect.id
  comment      = "IN-00: Anti-spoofing — drop internal src IPs from WAN"
}

# Brute-force: add source to blocklist after 3 new connections to management ports
resource "routeros_ip_firewall_filter" "in_00a_brute_detect" {
  action               = "add-src-to-address-list"
  chain                = "input"
  protocol             = "tcp"
  dst_port             = "22,8291"
  connection_state     = "new"
  connection_limit     = "3,32"
  address_list         = "brute_force_blocked"
  address_list_timeout = "1d"
  place_before         = routeros_ip_firewall_filter.in_00b_brute_drop.id
  comment              = "IN-00a: Brute-force detect — SSH/Winbox (3 attempts/IP)"
}

resource "routeros_ip_firewall_filter" "in_00b_brute_drop" {
  action           = "drop"
  chain            = "input"
  src_address_list = "brute_force_blocked"
  place_before     = routeros_ip_firewall_filter.in_01_established.id
  comment          = "IN-00b: Brute-force drop — blocked source list"
}

resource "routeros_ip_firewall_filter" "in_01_established" {
  action           = "accept"
  chain            = "input"
  connection_state = "established,related,untracked"
  place_before     = routeros_ip_firewall_filter.in_02_mgmt.id
  comment          = "IN-01: Allow established/related"
}

# ICMP restricted to internal networks only (no WAN ping response)
resource "routeros_ip_firewall_filter" "in_01a_icmp" {
  action       = "accept"
  chain        = "input"
  protocol     = "icmp"
  src_address  = "10.0.0.0/8"
  place_before = routeros_ip_firewall_filter.in_02_mgmt.id
  comment      = "IN-01a: Allow ICMP from internal networks only"
}

resource "routeros_ip_firewall_filter" "in_02a_srv_monitoring" {
  action       = "accept"
  chain        = "input"
  src_address  = "10.0.20.0/24"
  place_before = routeros_ip_firewall_filter.drop_all_input.id
  comment      = "IN-02a: Allow SRV (Monitoring) to Router"
}

resource "routeros_ip_firewall_filter" "in_02_mgmt" {
  action           = "accept"
  chain            = "input"
  src_address_list = "Mgmt_Devices"
  place_before     = routeros_ip_firewall_filter.drop_all_input.id
  comment          = "IN-02: Allow Admin-VLAN access to Router-API"
}

# ===============================================
# FORWARD CHAIN (Traffic THROUGH the Router)
# ===============================================

# Anti-spoofing: block internal source IPs arriving from WAN on forward chain
resource "routeros_ip_firewall_filter" "fwd_00b_antispoofing" {
  action       = "drop"
  chain        = "forward"
  src_address  = "10.0.0.0/8"
  in_interface = "ether1"
  place_before = routeros_ip_firewall_filter.fwd_00_fasttrack.id
  comment      = "00b: Anti-spoofing — drop RFC1918 src from WAN"
}

resource "routeros_ip_firewall_filter" "fwd_00_fasttrack" {
  action           = "fasttrack-connection"
  chain            = "forward"
  connection_state = "established,related"
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

resource "routeros_ip_firewall_filter" "fwd_01a_icmp" {
  action       = "accept"
  chain        = "forward"
  protocol     = "icmp"
  src_address  = "10.0.0.0/8"
  place_before = routeros_ip_firewall_filter.fwd_02_drop_invalid.id
  comment      = "01a: Global - Allow ICMP between internal networks"
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
  place_before = routeros_ip_firewall_filter.fwd_04_proxy_to_mgmt.id
  comment      = "03: Admin - Full access to all internal VLANs"
}

resource "routeros_ip_firewall_filter" "fwd_04_proxy_to_mgmt" {
  chain        = "forward"
  action       = "accept"
  src_address  = "10.0.20.0/24"
  dst_address  = "10.0.10.0/24"
  dst_port     = "8006,8007"
  protocol     = "tcp"
  place_before = routeros_ip_firewall_filter.fwd_04a_srv_monitoring.id
  comment      = "04: SRV - Internal Proxy access to MGMT Web GUIs"
}

# Scoped to port 9100 only (PBS node_exporter) — previously allowed all ports to all VLANs
resource "routeros_ip_firewall_filter" "fwd_04a_srv_monitoring" {
  action       = "accept"
  chain        = "forward"
  src_address  = "10.0.20.0/24"
  dst_address  = "10.0.10.0/24"
  dst_port     = "9100"
  protocol     = "tcp"
  place_before = routeros_ip_firewall_filter.fwd_08_allow_dns.id
  comment      = "04a: SRV - Prometheus scrape to MGMT node_exporter (port 9100)"
}

# DNS UDP
resource "routeros_ip_firewall_filter" "fwd_08_allow_dns" {
  action       = "accept"
  chain        = "forward"
  dst_address  = "10.0.20.5"
  dst_port     = "53"
  protocol     = "udp"
  place_before = routeros_ip_firewall_filter.fwd_08b_allow_dns_tcp.id
  comment      = "08: DNS - Allow internal DNS queries to AdGuard VIP (UDP)"
}

# DNS TCP (DNSSEC responses > 512 bytes, zone transfers)
resource "routeros_ip_firewall_filter" "fwd_08b_allow_dns_tcp" {
  action       = "accept"
  chain        = "forward"
  dst_address  = "10.0.20.5"
  dst_port     = "53"
  protocol     = "tcp"
  place_before = routeros_ip_firewall_filter.fwd_09_dmz_to_backends.id
  comment      = "08b: DNS - Allow internal DNS queries to AdGuard VIP (TCP)"
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

resource "routeros_ip_firewall_filter" "fwd_10_srv_to_wan" {
  action        = "accept"
  chain         = "forward"
  src_address   = "10.0.20.0/24"
  out_interface = "ether1"
  place_before  = routeros_ip_firewall_filter.fwd_11_dmz_to_wan.id
  comment       = "10: SRV - Internet access (Critical for Unbound DNS)"
}

resource "routeros_ip_firewall_filter" "fwd_11_dmz_to_wan" {
  action        = "accept"
  chain         = "forward"
  src_address   = "10.0.30.0/24"
  out_interface = "ether1"
  place_before  = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment       = "11: DMZ - Internet access only"
}
