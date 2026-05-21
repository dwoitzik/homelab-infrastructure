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
  id = "id-vlan40-iot" # This might be dynamic, check terraform plan
}

import {
  to = routeros_interface_vlan.vlans["vlan100-admin"]
  id = "vlan100-admin"
}

# Firewall Core
import {
  to = routeros_ip_firewall_filter.drop_all_input
  id = "input,drop,INPUT: Default drop"
}

import {
  to = routeros_ip_firewall_filter.fwd_00_fasttrack
  id = "forward,fasttrack-connection,00: Global - Fasttrack for CPU efficiency"
}

import {
  to = routeros_ip_firewall_filter.fwd_01_established
  id = "forward,accept,01: Global - Allow established/related"
}
