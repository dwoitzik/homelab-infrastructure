###############################################################################
# WAN & Internet Connectivity
###############################################################################

resource "routeros_ip_dhcp_client" "wan_client" {
  interface         = "ether1"
  add_default_route = "yes"
  use_peer_dns      = true
  use_peer_ntp      = true
}

resource "routeros_ip_firewall_nat" "masquerade" {
  chain         = "srcnat"
  out_interface = "ether1"
  action        = "masquerade"
  comment       = "Standard NAT for internet access"
}

resource "routeros_ip_firewall_filter" "drop_wan_input" {
  chain            = "input"
  in_interface     = "ether1"
  connection_state = "!established,related"
  action           = "drop"
  comment          = "Firewall: Drop all external input"
}

resource "routeros_ip_cloud" "ddns" {
  ddns_enabled = "yes"
  update_time  = true
}
