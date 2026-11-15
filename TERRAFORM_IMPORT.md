# Terraform State Import

How to re-adopt existing resources into a fresh Garage-backed state (ADR-003), for example
after state loss. Imports go through the same PR flow as every other change: add native
`import` blocks to the stack, comment `atlantis plan -d <stack>` on the PR, check that the
plan shows only imports and no changes, then `atlantis apply -d <stack>` (ADR-021). Remove
the `import` blocks once applied. The retired Atlantis server's `atlantis import` comment
command no longer exists; the workflows only run plan and apply.

## Network Stack (terraform/stacks/network)

```hcl
import {
  to = routeros_interface_bridge.core_bridge
  id = "bridge1"
}
import {
  to = routeros_interface_vlan.vlan10_mgmt
  id = "vlan10-mgmt"
}
import {
  to = routeros_ip_address.vlan10_ip
  id = "10.0.10.1/24"
}
import {
  to = routeros_ip_firewall_addr_list.mgmt_devices
  id = "Mgmt_Devices,10.0.10.0/24"
}
import {
  to = routeros_ip_firewall_addr_list.mgmt_admin
  id = "Mgmt_Devices,10.0.100.0/24"
}

# Firewall filter rules (input)
import {
  to = routeros_ip_firewall_filter.drop_all_input
  id = "input,drop,INPUT: Default drop"
}
import {
  to = routeros_ip_firewall_filter.in_01_established
  id = "input,accept,IN-01: Allow established/related"
}
import {
  to = routeros_ip_firewall_filter.in_02_mgmt
  id = "input,accept,IN-02: Allow Admin-VLAN access to Router-API"
}

# Firewall filter rules (forward)
import {
  to = routeros_ip_firewall_filter.drop_all_forward
  id = "forward,drop,FORWARD: Default drop"
}
import {
  to = routeros_ip_firewall_filter.fwd_01_established
  id = "forward,accept,01: Global - Allow established/related"
}
import {
  to = routeros_ip_firewall_filter.fwd_02_drop_invalid
  id = "forward,drop,02: Global - Drop invalid connections"
}
import {
  to = routeros_ip_firewall_filter.fwd_03_admin_any
  id = "forward,accept,03: ADM - Allow Admin-VLAN to any"
}

# DHCP servers
import {
  to = routeros_ip_dhcp_server.vlan10_dhcp
  id = "dhcp-vlan10"
}
import {
  to = routeros_ip_pool.vlan10_pool
  id = "pool-vlan10-mgmt"
}
```

## Proxmox Stack (terraform/stacks/proxmox)

```hcl
import {
  to = proxmox_virtual_environment_vm.vm_srv_k3s_11_master
  id = "pve-mgmt-01:211"
}
import {
  to = proxmox_virtual_environment_vm.vm_srv_k3s_12_worker
  id = "pve-mgmt-01:212"
}
import {
  to = proxmox_virtual_environment_vm.vm_srv_k3s_13_worker
  id = "pve-mgmt-01:213"
}

import {
  to = proxmox_virtual_environment_container.ct_mgmt_pbs_01
  id = "pve-mgmt-01:110"
}
import {
  to = proxmox_virtual_environment_container.ct_srv_docker_01
  id = "pve-mgmt-01:200"
}
import {
  to = proxmox_virtual_environment_container.ct_srv_ai_01
  id = "pve-mgmt-01:201"
}
import {
  to = proxmox_virtual_environment_container.ct_dmz_proxy_01
  id = "pve-mgmt-01:301"
}
import {
  to = proxmox_virtual_environment_container.ct_dmz_games_01
  id = "pve-mgmt-01:302"
}
```
