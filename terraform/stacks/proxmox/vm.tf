# --- K3s Kubernetes Cluster (VLAN 20 - srv) ---

resource "proxmox_virtual_environment_vm" "vm_srv_k3s_11_master" {
  vm_id     = 211
  name      = "vm-srv-k3s-11"
  node_name = local.target_node
  tags      = ["k3s", "master", "kubernetes"]
  started   = true

  # Staggered boot (2026-06-20): all 3 k3s VMs starting simultaneously caused a
  # resource storm (load avg 147 within 4 min of boot) that made the Proxmox host
  # unresponsive for several minutes. NFS server boots first (order 1), then
  # k3s nodes 30s apart. See docs/OPERATIONS.md.
  startup {
    order    = 2
    up_delay = 30
  }

  # disk and clone/initialization are creation-time only; ignore prevents Atlantis
  # from stopping the VM (and killing itself) on subsequent plans.
  lifecycle {
    ignore_changes = [clone, initialization, disk]
  }

  clone {
    vm_id = 9000
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 12288
    floating  = 8192
  }

  disk {
    datastore_id = local.storage
    interface    = "scsi0"
    size         = 120
    file_format  = "raw"
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 20
  }

  initialization {
    datastore_id = local.storage
    ip_config {
      ipv4 {
        address = "10.0.20.11/24"
        gateway = "10.0.20.1"
      }
    }
    dns {
      servers = ["10.0.20.5"]
    }
    user_account {
      username = "dw"
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJqyhlsY7Ji2Hv3tK1dz0TtAxgVP5quj8UP3JpJnnxL9"
      ]
    }
  }
}

resource "proxmox_virtual_environment_vm" "vm_srv_k3s_12_worker" {
  # memory capped at 8 GB (was 16 GB) — pure agent node, no etcd, no
  # Longhorn replicas scheduled here. Host has 64 GB max (DDR4 ceiling).
  vm_id     = 212
  name      = "vm-srv-k3s-12"
  node_name = local.target_node
  tags      = ["k3s", "worker", "kubernetes"]
  started   = true

  startup {
    order    = 3
    up_delay = 30
  }

  lifecycle {
    ignore_changes = [clone, initialization, disk]
  }

  clone {
    vm_id = 9000
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 8192
    floating  = 4096
  }

  disk {
    datastore_id = local.storage
    interface    = "scsi0"
    size         = 120
    file_format  = "raw"
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 20
  }

  initialization {
    datastore_id = local.storage
    ip_config {
      ipv4 {
        address = "10.0.20.12/24"
        gateway = "10.0.20.1"
      }
    }
    dns {
      servers = ["10.0.20.5"]
    }
    user_account {
      username = "dw"
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJqyhlsY7Ji2Hv3tK1dz0TtAxgVP5quj8UP3JpJnnxL9"
      ]
    }
  }
}

resource "proxmox_virtual_environment_vm" "vm_srv_k3s_13_worker" {
  # memory capped at 8 GB (was 16 GB) — pure agent node, same rationale as k3s-12.
  vm_id     = 213
  name      = "vm-srv-k3s-13"
  node_name = local.target_node
  tags      = ["k3s", "worker", "kubernetes"]
  started   = true

  startup {
    order    = 4
    up_delay = 30
  }

  lifecycle {
    ignore_changes = [clone, initialization, disk]
  }

  clone {
    vm_id = 9000
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 8192
    floating  = 4096
  }

  disk {
    datastore_id = local.storage
    interface    = "scsi0"
    size         = 120
    file_format  = "raw"
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 20
  }

  initialization {
    datastore_id = local.storage
    ip_config {
      ipv4 {
        address = "10.0.20.13/24"
        gateway = "10.0.20.1"
      }
    }
    dns {
      servers = ["10.0.20.5"]
    }
    user_account {
      username = "dw"
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJqyhlsY7Ji2Hv3tK1dz0TtAxgVP5quj8UP3JpJnnxL9"
      ]
    }
  }
}
