###############################################################################
# IPv6 Internal Addressing — ULA + NAT66
#
# MikroTik sits behind FritzBox which does NAT. The FritzBox advertises an
# IPv6 prefix via RA on its LAN, so ether1 gets a GUA via SLAAC automatically.
#
# Internally we use ULA (fd00::/8, RFC 4193) — one /64 per VLAN.
# NAT66 masquerades ULA source addresses to ether1's GUA for outbound traffic.
# Hosts receive their ULA via SLAAC (advertise = true enables RA per interface).
###############################################################################

locals {
  ipv6_ula_prefixes = {
    "vlan10-mgmt"   = "fd10::/64"
    "vlan20-srv"    = "fd20::/64"
    "vlan30-dmz"    = "fd30::/64"
    "vlan40-iot"    = "fd40::/64"
    "vlan100-admin" = "fd64::/64"
  }
}

resource "routeros_ipv6_address" "vlan_ula" {
  for_each = local.ipv6_ula_prefixes

  # Router address is ::1 in each /64
  address   = replace(each.value, "::/64", "::1/64")
  interface = each.key
  advertise = true
  comment   = "ULA gateway for ${each.key}"
}

# NAT66: masquerade internal ULA sources to the WAN GUA when leaving ether1.
# src_address is mandatory — without it, ALL IPv6 leaving ether1 is masqueraded,
# including traffic from FritzBox WiFi clients that use MikroTik as IPv6 gateway.
resource "routeros_ipv6_firewall_nat" "nat66_masquerade" {
  chain         = "srcnat"
  action        = "masquerade"
  src_address   = "fd00::/8"
  out_interface = "ether1"
  comment       = "NAT66: ULA → WAN GUA (FritzBox upstream)"
}

# MikroTik defaults to not accepting RA when forwarding is enabled.
# Set to "yes" so ether1 can receive a GUA prefix via SLAAC from FritzBox.
resource "routeros_ipv6_settings" "global" {
  accept_router_advertisements = "yes"
  forward                      = true
}

# RouterOS 7 enables RA advertisement on ALL interfaces by default — including
# ether1 (WAN). Once ether1 gets a GUA via SLAAC, MikroTik starts sending RAs
# on the FritzBox LAN. FritzBox WiFi clients then use MikroTik as their IPv6
# gateway, but the FORWARD chain only allows fd00::/8 sources → GUA clients
# are dropped → IPv6 broken on FritzBox WiFi.
# RA on ether1 is disabled in RouterOS: /ipv6/nd set [find interface=ether1] advertise=no
# routeros_ipv6_nd is not exposed in terraform-routeros/routeros ≤ 1.99.1 (latest as of 2026-06).
