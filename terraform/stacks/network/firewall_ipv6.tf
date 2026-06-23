###############################################################################
# IPv6 Firewall
# Strategy: NAT66 masquerade from internal ULA (fd00::/8) out through ether1.
# MikroTik gets a GUA on ether1 from FritzBox via SLAAC/RA.
#
# INPUT:   accept established + ICMPv6, drop everything else
# FORWARD: accept established + ICMPv6 + ULA→WAN, drop everything else
###############################################################################

# -----------------------------------------------------------------------
# INPUT chain
# -----------------------------------------------------------------------

resource "routeros_ipv6_firewall_filter" "v6_in_00_established" {
  action           = "accept"
  chain            = "input"
  connection_state = "established,related,untracked"
  place_before     = routeros_ipv6_firewall_filter.v6_in_01_icmpv6.id
  comment          = "V6-IN-00: Allow established/related"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ipv6_firewall_filter" "v6_in_01_icmpv6" {
  action       = "accept"
  chain        = "input"
  protocol     = "icmpv6"
  place_before = routeros_ipv6_firewall_filter.v6_input_drop_all.id
  comment      = "V6-IN-01: Allow ICMPv6 (NDP, RA, ping6)"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ipv6_firewall_filter" "v6_input_drop_all" {
  action  = "drop"
  chain   = "input"
  comment = "V6-IN-DROP: Drop all other IPv6 input"
}

# -----------------------------------------------------------------------
# FORWARD chain
# -----------------------------------------------------------------------

resource "routeros_ipv6_firewall_filter" "v6_fwd_00_established" {
  action           = "accept"
  chain            = "forward"
  connection_state = "established,related,untracked"
  place_before     = routeros_ipv6_firewall_filter.v6_fwd_01_icmpv6.id
  comment          = "V6-FWD-00: Allow established/related"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ipv6_firewall_filter" "v6_fwd_01_icmpv6" {
  action       = "accept"
  chain        = "forward"
  protocol     = "icmpv6"
  place_before = routeros_ipv6_firewall_filter.v6_fwd_02_internal_out.id
  comment      = "V6-FWD-01: Allow ICMPv6"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ipv6_firewall_filter" "v6_fwd_02_internal_out" {
  action        = "accept"
  chain         = "forward"
  src_address   = "fd00::/8"
  out_interface = "ether1"
  place_before  = routeros_ipv6_firewall_filter.v6_forward_drop_all.id
  comment       = "V6-FWD-02: Allow internal ULA to WAN"

  lifecycle {
    ignore_changes = [place_before]
  }
}

resource "routeros_ipv6_firewall_filter" "v6_forward_drop_all" {
  action  = "drop"
  chain   = "forward"
  comment = "V6-FWD-DROP: Drop all other IPv6 forward"
}
