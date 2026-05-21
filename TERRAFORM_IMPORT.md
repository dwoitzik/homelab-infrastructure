# Terraform State Import via Atlantis

The following commands must be posted as comments on a GitHub PR where Atlantis is active.
Atlantis will then import the existing resources into the new Garage-backed state.

## Network Stack (terraform/stacks/network)

```text
atlantis import -d terraform/stacks/network -- routeros_interface_bridge.core_bridge bridge1
atlantis import -d terraform/stacks/network -- routeros_interface_vlan.vlan10_mgmt vlan10-mgmt
atlantis import -d terraform/stacks/network -- routeros_ip_address.vlan10_ip "10.0.10.1/24"
atlantis import -d terraform/stacks/network -- routeros_ip_firewall_addr_list.mgmt_devices "Mgmt_Devices,10.0.10.0/24"
atlantis import -d terraform/stacks/network -- routeros_ip_firewall_addr_list.mgmt_admin "Mgmt_Devices,10.0.100.0/24"

# Firewall Filter Rules (Input)
atlantis import -d terraform/stacks/network -- routeros_ip_firewall_filter.drop_all_input "input,drop,INPUT: Default drop"
atlantis import -d terraform/stacks/network -- routeros_ip_firewall_filter.in_01_established "input,accept,IN-01: Allow established/related"
atlantis import -d terraform/stacks/network -- routeros_ip_firewall_filter.in_02_mgmt "input,accept,IN-02: Allow Admin-VLAN access to Router-API"

# Firewall Filter Rules (Forward)
atlantis import -d terraform/stacks/network -- routeros_ip_firewall_filter.drop_all_forward "forward,drop,FORWARD: Default drop"
atlantis import -d terraform/stacks/network -- routeros_ip_firewall_filter.fwd_01_established "forward,accept,01: Global - Allow established/related"
atlantis import -d terraform/stacks/network -- routeros_ip_firewall_filter.fwd_02_drop_invalid "forward,drop,02: Global - Drop invalid connections"
atlantis import -d terraform/stacks/network -- routeros_ip_firewall_filter.fwd_03_admin_any "forward,accept,03: ADM - Allow Admin-VLAN to any"

# DHCP Servers
atlantis import -d terraform/stacks/network -- routeros_ip_dhcp_server.vlan10_dhcp dhcp-vlan10
atlantis import -d terraform/stacks/network -- routeros_ip_pool.vlan10_pool pool-vlan10-mgmt
```

## Proxmox Stack (terraform/stacks/proxmox)

```text
atlantis import -d terraform/stacks/proxmox -- proxmox_virtual_environment_vm.vm_srv_k3s_11_master pve-mgmt-01:211
atlantis import -d terraform/stacks/proxmox -- proxmox_virtual_environment_vm.vm_srv_k3s_12_worker pve-mgmt-01:212
atlantis import -d terraform/stacks/proxmox -- proxmox_virtual_environment_vm.vm_srv_k3s_13_worker pve-mgmt-01:213

atlantis import -d terraform/stacks/proxmox -- proxmox_virtual_environment_container.ct_mgmt_pbs_01 pve-mgmt-01:110
atlantis import -d terraform/stacks/proxmox -- proxmox_virtual_environment_container.ct_srv_docker_01 pve-mgmt-01:200
atlantis import -d terraform/stacks/proxmox -- proxmox_virtual_environment_container.ct_srv_ai_01 pve-mgmt-01:201
atlantis import -d terraform/stacks/proxmox -- proxmox_virtual_environment_container.ct_dmz_proxy_01 pve-mgmt-01:301
atlantis import -d terraform/stacks/proxmox -- proxmox_virtual_environment_container.ct_dmz_games_01 pve-mgmt-01:302
```
