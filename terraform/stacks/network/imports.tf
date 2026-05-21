# MikroTik Network Foundation
import {
  to = routeros_interface_bridge.core_bridge
  id = "bridge1"
}

import {
  to = routeros_interface_vlan.vlan10_mgmt
  id = "vlan10-mgmt"
}

import {
  to = routeros_interface_vlan.vlans["vlan20-srv"]
  id = "vlan20-srv"
}

import {
  to = routeros_interface_vlan.vlans["vlan30-dmz"]
  id = "vlan30-dmz"
}

import {
  to = routeros_interface_vlan.vlans["vlan40-iot"]
  id = "vlan40-iot"
}

import {
  to = routeros_interface_vlan.vlans["vlan100-admin"]
  id = "vlan100-admin"
}

# Firewall Core (Using internal IDs found via REST API)
import {
  to = routeros_ip_firewall_filter.drop_all_input
  id = "*12" # Comment: INPUT: Default drop
}

import {
  to = routeros_ip_firewall_filter.fwd_99_drop_all
  id = "*11" # Comment: 99: Global - Final Drop (Zero Trust Policy)
}

import {
  to = routeros_ip_firewall_filter.fwd_01_established
  id = "*61" # Comment: 01: Global - Allow established/related
}

import {
  to = routeros_ip_firewall_filter.fwd_00_fasttrack
  id = "*5C" # Comment: 00: Global - Fasttrack for CPU efficiency
}
