###############################################################################
# WireGuard VPN Configuration (Roadwarrior)
###############################################################################

resource "routeros_wireguard" "wg_vpn" {
  name        = local.vpn_config.name
  listen_port = local.vpn_config.port
  comment     = "Remote Access VPN"
}

resource "routeros_ip_address" "wg_ip" {
  interface = routeros_wireguard.wg_vpn.name
  address   = "${cidrhost(local.vpn_config.subnet, 1)}/24"
}

###############################################################################
# Firewall Rules for VPN
###############################################################################

resource "routeros_ip_firewall_filter" "allow_wg_inbound" {
  chain            = "input"
  action           = "accept"
  protocol         = "udp"
  dst_port         = local.vpn_config.port
  in_interface     = "ether1"
  comment          = "VPN: Allow WireGuard Handshake"
}

resource "routeros_ip_firewall_filter" "allow_vpn_to_internal" {
  chain            = "forward"
  action           = "accept"
  src_address      = local.vpn_config.subnet
  dst_address      = "10.0.0.0/16"
  comment          = "VPN: Access to Homelab"
}

resource "routeros_wireguard_peer" "handy_dw" {
  interface       = routeros_wireguard.wg_vpn.name
  comment         = "Smartphone DW"
  public_key      = "X9iI0RGNf7kTxdBOs4CsDcOQtKRFMYALY/ugHv67uAo="
  allowed_address = ["10.6.0.2/32"]
  persistent_keepalive = "25s"
}
