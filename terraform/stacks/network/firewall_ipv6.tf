# IPv6 is not in use — MikroTik sits behind FritzBox NAT, no IPv6 prefix delegation needed.
# Drop all IPv6 traffic on both chains as defense-in-depth.

resource "routeros_ipv6_firewall_filter" "v6_input_drop_all" {
  action  = "drop"
  chain   = "input"
  comment = "V6-IN: Drop all IPv6 (disabled, behind FritzBox)"
}

resource "routeros_ipv6_firewall_filter" "v6_forward_drop_all" {
  action  = "drop"
  chain   = "forward"
  comment = "V6-FWD: Drop all IPv6 (disabled, behind FritzBox)"
}
