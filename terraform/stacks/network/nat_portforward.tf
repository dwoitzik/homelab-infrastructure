###############################################################################
# Inbound Port Forwards (WAN -> internal services)
# Last applied: 2026-07-01 (MC port forwards removed, playit.gg replaces WAN exposure)
#
# Minecraft (25565) and Cobblemon (25566) port forwards removed 2026-07-01:
# - Main Minecraft (25565): now routed via playit.gg tunnel (mc.woitzik.dev
#   CNAME in cloudflare stack). FritzBox WAN ports closed.
# - Cobblemon (25566): internal-only going forward, no external access.
# Matching forward-chain rules (fwd_wan_minecraft, fwd_wan_cobblemon) also
# removed from firewall_extra.tf.
# removed blocks tell Terraform to destroy these resources that no longer exist
# in config. Workaround for TF "Resource has no configuration" bug (#34992)
# that fires when removing routeros resources without explicit removed blocks.
removed {
  from = routeros_ip_firewall_nat.dstnat_minecraft
  lifecycle { destroy = true }
}
removed {
  from = routeros_ip_firewall_nat.dstnat_cobblemon
  lifecycle { destroy = true }
}

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

# Same class of problem as MGMT->SRV above, hit by Admin VLAN (100) instead:
# without this, Admin-VLAN clients (e.g. LXC 100 on the Proxmox trunk) could
# reach the AdGuard VIP (10.0.20.5) per the firewall filter rules, but DNS
# queries still timed out -- return traffic wasn't routing back correctly.
resource "routeros_ip_firewall_nat" "srcnat_masquerade_admin_to_srv" {
  chain       = "srcnat"
  action      = "masquerade"
  src_address = "10.0.100.0/24"
  dst_address = "10.0.20.0/24"
  comment     = "NAT: Masquerade Admin to SRV for return traffic"
}
