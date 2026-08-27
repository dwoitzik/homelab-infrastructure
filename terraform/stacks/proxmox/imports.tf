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

# ADR-027 backlog: these 3 LXCs (lxc.tf) were added after this file's
# original skeleton and never got import blocks -- same "declared, applied
# live, never brought into state" gap as several resources fixed in
# terraform/stacks/network this same pass. VMIDs confirmed live via
# `pct list` on pve-mgmt-01 (read-only, no RouterOS/Terraform credential
# needed), not guessed.
import {
  to = proxmox_virtual_environment_container.ct_srv_media_acq_01
  id = "pve-mgmt-01/202"
}

import {
  to = proxmox_virtual_environment_container.ct_srv_jellyfin_01
  id = "pve-mgmt-01/203"
}

import {
  to = proxmox_virtual_environment_container.ct_srv_atlantis_01
  id = "pve-mgmt-01/204"
}
