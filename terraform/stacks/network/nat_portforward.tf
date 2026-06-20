###############################################################################
# Inbound Port Forwards (WAN -> internal services)
#
# Requires a matching port-forward on the Fritzbox (upstream of ether1) to
# 192.168.178.10 (this router's WAN-side IP) for each port below — MikroTik
# only sees the Fritzbox's LAN, not the real internet-facing public IP.
###############################################################################

# Cobblemon Minecraft server (Fabric) — ct-dmz-games-01, second instance on 25566
resource "routeros_ip_firewall_nat" "dstnat_cobblemon" {
  chain        = "dstnat"
  action       = "dst-nat"
  protocol     = "tcp"
  dst_port     = "25566"
  in_interface = "ether1"
  to_addresses = "10.0.30.3"
  to_ports     = "25566"
  comment      = "DNAT: Cobblemon Minecraft -> ct-dmz-games-01"
}

resource "routeros_ip_firewall_filter" "fwd_12_wan_to_cobblemon" {
  action       = "accept"
  chain        = "forward"
  protocol     = "tcp"
  dst_address  = "10.0.30.3"
  dst_port     = "25566"
  in_interface = "ether1"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "12: WAN -> Cobblemon Minecraft (ct-dmz-games-01:25566)"
}
