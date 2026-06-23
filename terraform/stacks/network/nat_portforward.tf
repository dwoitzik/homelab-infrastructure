###############################################################################
# Inbound Port Forwards (WAN -> internal services)
#
# Requires a matching port-forward on the Fritzbox (upstream of ether1) to
# 192.168.178.10 (this router's WAN-side IP) for each port below — MikroTik
# only sees the Fritzbox's LAN, not the real internet-facing public IP.
###############################################################################

# Cobblemon Minecraft server (Fabric) — routed through ct-dmz-proxy-01 (NPM
# stream + CrowdSec), same pattern as the existing Minecraft server on 25565.
# NPM then forwards 25566 -> ct-dmz-games-01:25566 internally.
resource "routeros_ip_firewall_nat" "dstnat_cobblemon" {
  chain        = "dstnat"
  action       = "dst-nat"
  protocol     = "tcp"
  dst_port     = "25566"
  in_interface = "ether1"
  to_addresses = "10.0.30.2"
  to_ports     = "25566"
  comment      = "DNAT: Cobblemon Minecraft -> ct-dmz-proxy-01 (NPM stream)"
}

# NOTE: the matching forward-chain accept rule for this port already exists
# as routeros_ip_firewall_filter.fwd_wan_cobblemon in firewall_extra.tf
# (imported from the live router, id *B5). A duplicate "fwd_12_wan_to_cobblemon"
# resource with identical attributes used to live here too — same comment,
# same match criteria — which would have claimed the same live object under a
# second Terraform address. Removed 2026-06-23 while rebuilding network state
# (GIT-007); only the NAT rule belongs in this file.
