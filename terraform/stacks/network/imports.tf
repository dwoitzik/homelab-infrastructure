# MikroTik Foundation (Bridge & VLANs)
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

# Bridge Ports
import {
  to = routeros_interface_bridge_port.mgmt_port
  id = "*1"
}

import {
  to = routeros_interface_bridge_port.rpi_ports["ether6"]
  id = "*2"
}

import {
  to = routeros_interface_bridge_port.rpi_ports["ether7"]
  id = "*3"
}

import {
  to = routeros_interface_bridge_port.proxmox_port
  id = "*4"
}

# Bridge VLANs
import {
  to = routeros_interface_bridge_vlan.vlan10
  id = "*10"
}

import {
  to = routeros_interface_bridge_vlan.vlan_matrix["vlan20-srv"]
  id = "*12"
}

import {
  to = routeros_interface_bridge_vlan.vlan_matrix["vlan30-dmz"]
  id = "*6"
}

import {
  to = routeros_interface_bridge_vlan.vlan_matrix["vlan40-iot"]
  id = "*8"
}

import {
  to = routeros_interface_bridge_vlan.vlan_matrix["vlan100-admin"]
  id = "*A"
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

# DHCP Infrastructure
import {
  to = routeros_ip_pool.vlan10_pool
  id = "*5"
}

import {
  to = routeros_ip_pool.vlan_pools["vlan100-admin"]
  id = "*3"
}

import {
  to = routeros_ip_pool.vlan_pools["vlan20-srv"]
  id = "*4"
}

import {
  to = routeros_ip_pool.vlan_pools["vlan30-dmz"]
  id = "*1"
}

import {
  to = routeros_ip_pool.vlan_pools["vlan40-iot"]
  id = "*2"
}

import {
  to = routeros_ip_dhcp_server.vlan10_dhcp
  id = "*5"
}

import {
  to = routeros_ip_dhcp_server.vlan_dhcp["vlan100-admin"]
  id = "*3"
}

import {
  to = routeros_ip_dhcp_server.vlan_dhcp["vlan20-srv"]
  id = "*4"
}

import {
  to = routeros_ip_dhcp_server.vlan_dhcp["vlan30-dmz"]
  id = "*2"
}

import {
  to = routeros_ip_dhcp_server.vlan_dhcp["vlan40-iot"]
  id = "*1"
}

import {
  to = routeros_ip_dhcp_server_network.vlan10_network
  id = "*5"
}

import {
  to = routeros_ip_dhcp_server_network.vlan_networks["vlan100-admin"]
  id = "*1"
}

import {
  to = routeros_ip_dhcp_server_network.vlan_networks["vlan20-srv"]
  id = "*2"
}

import {
  to = routeros_ip_dhcp_server_network.vlan_networks["vlan30-dmz"]
  id = "*3"
}

import {
  to = routeros_ip_dhcp_server_network.vlan_networks["vlan40-iot"]
  id = "*4"
}

import {
  to = routeros_ip_dhcp_server_lease.server_nodes["ct-srv-docker-01"]
  id = "*10"
}

import {
  to = routeros_ip_dhcp_server_lease.server_nodes["rpi-srv-01"]
  id = "*12"
}

import {
  to = routeros_ip_dhcp_server_lease.server_nodes["rpi-srv-02"]
  id = "*11"
}

import {
  to = routeros_ip_dhcp_server_lease.mgmt_nodes["ct-mgmt-pbs-01"]
  id = "*16"
}

import {
  to = routeros_ip_dhcp_client.wan_client
  id = "*1"
}

import {
  to = routeros_ip_cloud.ddns
  id = "ip.cloud"
}

import {
  to = routeros_ip_firewall_mangle.mss_clamp
  id = "*1"
}

# Firewall Core
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

# System Settings
import {
  to = routeros_snmp_community.monitoring
  id = "*1"
}

import {
  to = routeros_system_script.leds_on
  id = "*1"
}

import {
  to = routeros_system_script.leds_off
  id = "*2"
}

import {
  to = routeros_system_scheduler.day_mode
  id = "*1"
}

import {
  to = routeros_system_scheduler.night_mode
  id = "*0"
}
