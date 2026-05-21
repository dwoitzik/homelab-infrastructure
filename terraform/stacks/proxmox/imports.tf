# Proxmox VMs & Containers
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
