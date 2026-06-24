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

###############################################################################
# Outbound NAT (GIT-009) — these two srcnat rules existed live but were never
# declared in Terraform at all; basic internet access for the whole homelab
# depended on undocumented, unmanaged router config.
###############################################################################

# Outbound internet masquerade for everything behind ether1 (WAN).
#
# Live rule (*5) actually stores this match as out-interface-list pointing at
# interface-list id *2000010 — but that list no longer exists (confirmed via
# GET /rest/interface/list against the live router: only the 4 RouterOS
# builtin lists remain). The rule still passes real traffic (1262 pkts /
# ~190KB at time of writing) because RouterOS keeps matching on the cached
# internal reference even though the management API can no longer resolve it
# to a name. Declaring this as a plain out_interface = "ether1" match instead
# of trying to recreate the dangling list — ether1 is the WAN interface
# everywhere else in this codebase, and this is the simpler, supportable
# config going forward.
resource "routeros_ip_firewall_nat" "srcnat_masquerade_wan" {
  chain         = "srcnat"
  action        = "masquerade"
  out_interface = "ether1"
  ipsec_policy  = "out,none"
  comment       = "NAT: Outbound Internet Access"
}

# Masquerade MGMT (VLAN 10) -> SRV (VLAN 20) so return traffic routes back
# correctly — e.g. PBS/Proxmox on VLAN 10 reaching services on VLAN 20.
resource "routeros_ip_firewall_nat" "srcnat_masquerade_mgmt_to_srv" {
  chain       = "srcnat"
  action      = "masquerade"
  src_address = "10.0.10.0/24"
  dst_address = "10.0.20.0/24"
  comment     = "NAT: Masquerade MGMT to SRV for return traffic"
}
