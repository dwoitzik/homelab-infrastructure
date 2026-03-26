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
# Peers
###############################################################################

resource "routeros_wireguard_peer" "handy_dw" {
  interface       = routeros_wireguard.wg_vpn.name
  comment         = "Smartphone DW - Limited Access"
  public_key      = "X9iI0RGNf7kTxdBOs4CsDcOQtKRFMYALY/ugHv67uAo="
  allowed_address = [local.vpn_handy_ip]
  persistent_keepalive = "25s"
}

resource "routeros_wireguard_peer" "laptop_dw" {
  interface       = routeros_wireguard.wg_vpn.name
  comment         = "Laptop DW - Full Admin Access"
  public_key      = "mE7EAs5FqZ49rGjA71A7p5pPZ6nLzV6/u6u6u6u6u6u="
  allowed_address = [local.vpn_laptop_ip]
  persistent_keepalive = "25s"
}
