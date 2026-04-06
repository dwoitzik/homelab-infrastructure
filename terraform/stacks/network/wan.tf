###############################################################################
# WAN & Internet Connectivity
###############################################################################

resource "routeros_ip_dhcp_client" "wan_client" {
  interface         = "ether1"
  add_default_route = "yes"
  use_peer_dns      = true
  use_peer_ntp      = true
}

resource "routeros_ip_cloud" "ddns" {
  ddns_enabled = "yes"
  update_time  = true
}
