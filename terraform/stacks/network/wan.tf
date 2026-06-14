###############################################################################
# WAN
###############################################################################

resource "routeros_ip_dhcp_client" "wan_client" {
  interface         = "ether1"
  add_default_route = "yes"
  use_peer_dns      = false
  use_peer_ntp      = false
}

resource "routeros_ip_cloud" "ddns" {
  ddns_enabled = "yes"
  update_time  = true
}

resource "routeros_system_ntp_client" "ntp" {
  enabled = true
  servers = ["0.pool.ntp.org", "1.pool.ntp.org"]
}
