# MikroTik Foundation (VLANs)
import {
  to = routeros_interface_bridge.core_bridge
  id = "bridge1"
}

import {
  to = routeros_interface_vlan.vlan10_mgmt
  id = "*C"
}

import {
  to = routeros_interface_vlan.vlans["vlan20-srv"]
  id = "*E"
}

import {
  to = routeros_interface_vlan.vlans["vlan30-dmz"]
  id = "*D"
}

import {
  to = routeros_interface_vlan.vlans["vlan40-iot"]
  id = "*10"
}

import {
  to = routeros_interface_vlan.vlans["vlan100-admin"]
  id = "*F"
}

# IP Addresses
import {
  to = routeros_ip_address.vlan10_ip
  id = "*4"
}

import {
  to = routeros_ip_address.vlan_ips["vlan20-srv"]
  id = "*7"
}

import {
  to = routeros_ip_address.vlan_ips["vlan30-dmz"]
  id = "*6"
}

import {
  to = routeros_ip_address.vlan_ips["vlan40-iot"]
  id = "*5"
}

import {
  to = routeros_ip_address.vlan_ips["vlan100-admin"]
  id = "*8"
}

# Address Lists
import {
  to = routeros_ip_firewall_addr_list.mgmt_admin
  id = "*7"
}

import {
  to = routeros_ip_firewall_addr_list.internal_networks["vlan100-admin"]
  id = "*8"
}

import {
  to = routeros_ip_firewall_addr_list.internal_networks["vlan30-dmz"]
  id = "*9"
}

import {
  to = routeros_ip_firewall_addr_list.internal_networks["vlan40-iot"]
  id = "*A"
}

import {
  to = routeros_ip_firewall_addr_list.internal_networks["vlan20-srv"]
  id = "*B"
}

# Firewall Core (Using internal IDs found via REST API)
import {
  to = routeros_ip_firewall_filter.drop_all_input
  id = "*12"
}

import {
  to = routeros_ip_firewall_filter.fwd_99_drop_all
  id = "*11"
}

import {
  to = routeros_ip_firewall_filter.fwd_01_established
  id = "*61"
}

import {
  to = routeros_ip_firewall_filter.fwd_00_fasttrack
  id = "*5C"
}
