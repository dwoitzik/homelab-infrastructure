locals {
  target_node = "pve-mgmt-01"
  storage     = "local-zfs"
  template    = "usb-templates:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}

# --- Management Stack ---

resource "proxmox_virtual_environment_container" "ct_mgmt_pbs_01" {
  vm_id        = 110
  node_name    = local.target_node
  tags         = ["backup", "community-script"]
  started      = true
  unprivileged = true

  initialization {
    hostname = "ct-mgmt-pbs-01"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
      ipv6 {
        address = "auto"
      }
    }
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
    swap      = 512
  }

  features {
    nesting = true
    fuse    = true
  }

  disk {
    datastore_id = local.storage
    size         = 10
  }

  mount_point {
    volume = "/mnt/pbs-storage"
    path   = "/mnt/backups"
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "bc:24:11:24:7a:71"
    vlan_id     = 10
  }

  operating_system {
    template_file_id = local.template
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [
      description,
      initialization[0].user_account,
      operating_system[0].template_file_id,
      network_interface[0].mac_address,
    ]
  }
}

# --- Server Stack ---

resource "proxmox_virtual_environment_container" "ct_srv_docker_01" {
  vm_id        = 200
  node_name    = local.target_node
  started      = true
  unprivileged = true

  initialization {
    hostname = "ct-srv-docker-01"
  }

  cpu {
    cores = 4
  }

  memory {
    dedicated = 4096
    swap      = 4096
  }

  features {
    nesting = true
    keyctl  = true
  }

  disk {
    datastore_id = local.storage
    size         = 40
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "bc:24:11:85:76:c5"
    vlan_id     = 20
    firewall    = true
  }

  operating_system {
    template_file_id = local.template
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [
      description,
      initialization[0].user_account,
      operating_system[0].template_file_id,
      network_interface[0].mac_address,
    ]
  }
}

# --- AI & LLM Stack ---

resource "proxmox_virtual_environment_container" "ct_srv_ai_01" {
  vm_id        = 201
  node_name    = local.target_node
  started      = true
  unprivileged = true

  initialization {
    hostname = "ct-srv-ai-01"
  }

  cpu {
    cores = 8
  }

  memory {
    dedicated = 32768
    swap      = 8192
  }

  features {
    nesting = true
    keyctl  = true
  }

  disk {
    datastore_id = local.storage
    size         = 80
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "bc:24:11:55:aa:f5"
    vlan_id     = 20
    firewall    = true
  }

  operating_system {
    template_file_id = local.template
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [
      description,
      initialization[0].user_account,
      operating_system[0].template_file_id,
      network_interface[0].mac_address,
    ]
  }
}

# --- DMZ Stack ---

resource "proxmox_virtual_environment_container" "ct_dmz_proxy_01" {
  vm_id        = 301
  node_name    = local.target_node
  started      = true
  unprivileged = true

  initialization {
    hostname = "ct-dmz-proxy-01"
    ip_config {
      ipv4 {
        address = "10.0.30.2/24"
        gateway = "10.0.30.1"
      }
    }
    dns {
      servers = ["1.1.1.1", "8.8.8.8"]
    }
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 1024
    swap      = 512
  }

  features {
    nesting = true
  }

  disk {
    datastore_id = local.storage
    size         = 8
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "bc:24:11:32:8c:27"
    vlan_id     = 30
    firewall    = true
  }

  operating_system {
    template_file_id = local.template
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [
      description,
      initialization[0].user_account,
      operating_system[0].template_file_id,
      network_interface[0].mac_address,
      features,
    ]
  }
}

resource "proxmox_virtual_environment_container" "ct_dmz_games_01" {
  vm_id        = 302
  node_name    = local.target_node
  started      = true
  unprivileged = true

  initialization {
    hostname = "ct-dmz-games-01"
    ip_config {
      ipv4 {
        address = "10.0.30.3/24"
        gateway = "10.0.30.1"
      }
    }
    dns {
      servers = ["1.1.1.1", "8.8.8.8"]
    }
  }

  cpu {
    cores = 4
  }

  memory {
    dedicated = 4096
    swap      = 512
  }

  features {
    nesting = true
  }

  disk {
    datastore_id = local.storage
    size         = 30
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "bc:24:11:2e:76:f4"
    vlan_id     = 30
    firewall    = true
  }

  operating_system {
    template_file_id = local.template
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [
      description,
      initialization[0].user_account,
      operating_system[0].template_file_id,
      network_interface[0].mac_address,
    ]
  }
}
