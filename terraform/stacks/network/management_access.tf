# MAC-Telnet/MAC-WinBox bypass the IP firewall; on ether1 they were open to the
# whole FritzBox LAN. ether4 is the non-bridged out-of-band port. ADR-085.
resource "routeros_interface_list" "mac_access" {
  name    = "mac-access"
  comment = "Interfaces that accept MAC-Telnet/MAC-WinBox, ADR-085"
}

resource "routeros_interface_list_member" "mac_access" {
  for_each  = toset(["ether4", "bridge1", "vlan10-mgmt", "vlan100-admin"])
  list      = routeros_interface_list.mac_access.name
  interface = each.value
}

resource "routeros_tool_mac_server" "this" {
  allowed_interface_list = routeros_interface_list.mac_access.name

  depends_on = [routeros_interface_list_member.mac_access]
}

resource "routeros_tool_mac_server_winbox" "this" {
  allowed_interface_list = routeros_interface_list.mac_access.name

  depends_on = [routeros_interface_list_member.mac_access]
}
