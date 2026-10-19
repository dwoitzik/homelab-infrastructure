# removed blocks for MC firewall rules deleted 2026-07-01 (PR #216).
# Explicit removed blocks required to avoid TF "Resource has no configuration" bug.
removed {
  from = routeros_ip_firewall_filter.fwd_wan_minecraft
  lifecycle { destroy = true }
}
removed {
  from = routeros_ip_firewall_filter.fwd_wan_cobblemon
  lifecycle { destroy = true }
}

# ===============================================
# Rules that existed live on the router but were never added to Terraform.
# Found during the 2026-06-21 firewall audit (see CHANGELOG/OPERATIONS.md).
# All confirmed either still functionally required or carrying real traffic
# at the time of import. Three additional WireGuard-specific rules from the
# same audit were NOT imported here - WireGuard has zero interfaces/peers
# configured (decommissioned in favor of Headscale/Tailscale) and those rules
# carried zero traffic, so they were deleted outright instead.
# ===============================================

resource "routeros_ip_firewall_filter" "in_03_admin_router_api" {
  action           = "accept"
  chain            = "input"
  src_address_list = "Mgmt_Devices"
  place_before     = routeros_ip_firewall_filter.drop_all_input.id
  comment          = "IN-03: Allow Admin-VLAN access to Router-API"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ip_firewall_filter" "in_06_snmp" {
  action       = "accept"
  chain        = "input"
  protocol     = "udp"
  dst_port     = "161"
  src_address  = "10.0.20.0/24"
  place_before = routeros_ip_firewall_filter.drop_all_input.id
  comment      = "IN-06: Allow SNMP from SRV-Net (Monitoring)"

  lifecycle {
    ignore_changes = [place_before]
  }
}

# Comment kept close to the original on purpose - the rule still carries real
# traffic (142MB+ at audit time) despite MikroDash itself being decommissioned
# (see CHANGELOG 0.5.0). Likely picked up by a newer K3s-hosted consumer of
# the router's binary API ports; exact consumer not identified as of
# 2026-06-21. Do not remove without confirming nothing depends on it first.
resource "routeros_ip_firewall_filter" "in_05_k3s_router_api" {
  action       = "accept"
  chain        = "input"
  protocol     = "tcp"
  dst_port     = "8728,8729"
  src_address  = "10.0.20.0/24"
  place_before = routeros_ip_firewall_filter.drop_all_input.id
  comment      = "IN-05: Allow router API access from K3s Nodes (legacy MikroDash grant, current consumer unconfirmed, active traffic present)"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ip_firewall_filter" "in_04_atlantis_api" {
  action       = "accept"
  chain        = "input"
  protocol     = "tcp"
  dst_port     = "443"
  src_address  = "10.0.20.0/24"
  place_before = routeros_ip_firewall_filter.drop_all_input.id
  comment      = "IN-04: Allow Atlantis REST API access from K3s Nodes"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ip_firewall_filter" "fwd_vpn_mobile_dmz" {
  action       = "accept"
  chain        = "forward"
  src_address  = "10.6.0.2"
  dst_address  = "10.0.30.0/24"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "08: VPN - Mobile access to DMZ (External Proxy)"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ip_firewall_filter" "fwd_vpn_mobile_internal" {
  action       = "accept"
  chain        = "forward"
  src_address  = "10.6.0.2"
  dst_address  = "10.0.20.0/24"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "07: VPN - Mobile limited to internal services"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ip_firewall_filter" "fwd_vpn_laptop_full" {
  action       = "accept"
  chain        = "forward"
  src_address  = "10.6.0.3"
  dst_address  = "10.0.0.0/16"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "06: VPN - Laptop Full Access"

  lifecycle {
    ignore_changes = [place_before]
  }
}

# src_address was a single host (ct-srv-docker-01) from before Prometheus
# moved into k3s -- the actual scraper (a pod on vm-srv-k3s-12) was never
# covered by this rule, causing a permanent TargetDown for these exporters.
resource "routeros_ip_firewall_filter" "fwd_monitoring_dmz_scrape" {
  action       = "accept"
  chain        = "forward"
  protocol     = "tcp"
  src_address  = "10.0.20.0/24"
  dst_address  = "10.0.30.0/24"
  dst_port     = "9100,9080"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "05: Monitoring - Prometheus scrape DMZ node exporters"

  lifecycle {
    ignore_changes = [place_before]
  }
}


resource "routeros_ip_firewall_filter" "fwd_mgmt_internet" {
  action        = "accept"
  chain         = "forward"
  src_address   = "10.0.10.0/24"
  out_interface = "ether1"
  place_before  = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment       = "11: MGMT - Internet access (Critical for PBS rclone & Updates)"

  lifecycle {
    ignore_changes = [place_before]
  }
}


resource "routeros_ip_firewall_filter" "fwd_vpn_full_tunnel" {
  action        = "accept"
  chain         = "forward"
  src_address   = "10.6.0.0/24"
  out_interface = "ether1"
  place_before  = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment       = "14: VPN - Allow Internet Access for Full Tunnel"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ip_firewall_filter" "fwd_proxmox_oidc" {
  action       = "accept"
  chain        = "forward"
  protocol     = "tcp"
  src_address  = "10.0.10.0/24"
  dst_address  = "10.0.20.5"
  dst_port     = "443"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "15: MGMT - Allow Proxmox to reach internal Proxy for OIDC"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ip_firewall_filter" "fwd_heimnetz_k3s_ingress" {
  action       = "accept"
  chain        = "forward"
  protocol     = "tcp"
  src_address  = "192.168.178.0/24"
  dst_address  = "10.0.20.200"
  dst_port     = "80,443"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "18: Heimnetz - Allow access to K3s Ingress (Core Services)"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ip_firewall_filter" "fwd_mgmt_oidc_traefik" {
  action       = "accept"
  chain        = "forward"
  protocol     = "tcp"
  src_address  = "10.0.10.0/24"
  dst_address  = "10.0.20.200"
  dst_port     = "443"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "17: MGMT - Allow OIDC traffic to K3s Traefik VIP"

  lifecycle {
    ignore_changes = [place_before]
  }
}

# ADR-027 backlog, corrected: an earlier pass here flagged this resource as
# having no `import` block and assumed it was a live-but-unadopted risk,
# same class as wan_egress_sqm/mgmt_port/vlan10. Checked against a real
# live plan instead of guessing further: it's already in state (id *B8,
# confirmed via `terraform plan` showing a clean refresh and zero diff for
# it) -- someone ran a one-off `terraform import` for it previously without
# ever adding the matching declarative block. Not a risk, just a
# documentation gap; the import block below closes it so a fresh
# `terraform init` from scratch (state loss, GIT-007-style) would still
# adopt it correctly instead of trying to create a duplicate.
resource "routeros_ip_firewall_filter" "fwd_k3s_nfs_media" {
  action       = "accept"
  chain        = "forward"
  protocol     = "tcp"
  src_address  = "10.0.20.0/24"
  dst_address  = "10.0.10.10"
  dst_port     = "2049"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "19: Server VLAN -> MGMT NFSv4 export for Jellyfin/usenet media PVC (mnt/media)"
}

# Minecraft is the one player-facing service that has to be reachable from
# places the DMZ is otherwise walled off from -- see ADR-055. Scoped to the two
# TCP ports the game speaks, to the DMZ only.
resource "routeros_ip_firewall_filter" "fwd_internal_to_dmz_minecraft" {
  action       = "accept"
  chain        = "forward"
  protocol     = "tcp"
  src_address  = "10.0.0.0/8"
  dst_address  = "10.0.30.0/24"
  dst_port     = "25565,25566"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "20: Internal - Minecraft to DMZ (game LXC + NPM stream proxy)"

  lifecycle {
    ignore_changes = [place_before]
  }
}

# FritzBox-LAN players reach the same service through the NPM stream proxy;
# masquerade needed for return traffic, same reason as the Heimnetz->SRV NAT.
resource "routeros_ip_firewall_filter" "fwd_heimnetz_to_dmz_minecraft" {
  action       = "accept"
  chain        = "forward"
  protocol     = "tcp"
  src_address  = "192.168.178.0/24"
  dst_address  = "10.0.30.0/24"
  dst_port     = "25565,25566"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "21: Heimnetz - Minecraft to DMZ (NPM stream proxy)"

  lifecycle {
    ignore_changes = [place_before]
  }
}

# Enshrouded dedicated server: UDP game (15636) + query (15637) ports, same
# LAN-to-DMZ pattern as Minecraft above. Remote players use the playit.gg
# tunnel instead, this is the direct-LAN path.
resource "routeros_ip_firewall_filter" "fwd_internal_to_dmz_enshrouded" {
  action       = "accept"
  chain        = "forward"
  protocol     = "udp"
  src_address  = "10.0.0.0/8"
  dst_address  = "10.0.30.0/24"
  dst_port     = "15636,15637"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "22: Internal - Enshrouded to DMZ (game LXC)"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ip_firewall_filter" "fwd_heimnetz_to_dmz_enshrouded" {
  action       = "accept"
  chain        = "forward"
  protocol     = "udp"
  src_address  = "192.168.178.0/24"
  dst_address  = "10.0.30.0/24"
  dst_port     = "15636,15637"
  place_before = routeros_ip_firewall_filter.fwd_99_drop_all.id
  comment      = "23: Heimnetz - Enshrouded to DMZ"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ipv6_firewall_filter" "v6_block_rogue_ra" {
  action        = "drop"
  chain         = "output"
  protocol      = "icmpv6"
  icmp_options  = "134:0"
  out_interface = "ether1"
  comment       = "Block rogue RA on WAN — prevents FritzBox WiFi clients using MikroTik as IPv6 gateway"
}
