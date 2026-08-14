import {
  to = proxmox_virtual_environment_container.ct_mgmt_pbs_01
  id = "pve-mgmt-01/110"
}

import {
  to = proxmox_virtual_environment_container.ct_srv_docker_01
  id = "pve-mgmt-01/200"
}

import {
  to = proxmox_virtual_environment_container.ct_srv_ai_01
  id = "pve-mgmt-01/201"
}

import {
  to = proxmox_virtual_environment_container.ct_dmz_proxy_01
  id = "pve-mgmt-01/301"
}

import {
  to = proxmox_virtual_environment_container.ct_dmz_games_01
  id = "pve-mgmt-01/302"
}

import {
  to = proxmox_virtual_environment_container.ct_srv_nfs_01
  id = "pve-mgmt-01/220"
}

import {
  to = proxmox_virtual_environment_vm.vm_srv_k3s_11_master
  id = "pve-mgmt-01/211"
}

import {
  to = proxmox_virtual_environment_vm.vm_srv_k3s_12_worker
  id = "pve-mgmt-01/212"
}

import {
  to = proxmox_virtual_environment_vm.vm_srv_k3s_13_worker
  id = "pve-mgmt-01/213"
}

import {
  to = proxmox_cluster_options.datacenter
  id = "cluster"
}

# atlantis-auth-verification-noop
