locals {
  target_node = "pve-mgmt-01"
  storage     = "local-zfs"
  template    = "usb-templates:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}

# --- Management Stack ---

resource "proxmox_virtual_environment_container" "ct_mgmt_pbs_01" {
  vm_id        = 110
  node_name    = local.target_node
  tags         = ["backup", "management"]
  started      = true
  unprivileged = true

  startup {
    order    = 5
    up_delay = 10
  }

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

  disk {
    datastore_id = local.storage
    size         = 10
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
    ignore_changes = all
  }
}

# --- Server Stack ---

resource "proxmox_virtual_environment_container" "ct_srv_docker_01" {
  vm_id                 = 200
  node_name             = local.target_node
  tags                  = ["docker", "server", "services"]
  started               = true
  unprivileged          = true
  environment_variables = {}

  startup {
    order    = 5
    up_delay = 10
  }

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
      features,
    ]
  }
}

# --- AI & LLM Stack ---

resource "proxmox_virtual_environment_container" "ct_srv_ai_01" {
  vm_id                 = 201
  node_name             = local.target_node
  tags                  = ["ai", "llm", "server"]
  started               = true
  unprivileged          = true
  environment_variables = {}

  startup {
    order    = 5
    up_delay = 10
  }

  initialization {
    hostname = "ct-srv-ai-01"
    ip_config {
      ipv4 {
        address = "10.0.20.251/24"
        gateway = "10.0.20.1"
      }
    }
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

  # AMD Vega iGPU passthrough for Ollama (ROCm) — render node + compute device.
  device_passthrough {
    path       = "/dev/dri/renderD128"
    uid        = 0
    gid        = 992
    mode       = "0660"
    deny_write = false
  }

  device_passthrough {
    path       = "/dev/kfd"
    uid        = 0
    gid        = 992
    mode       = "0660"
    deny_write = false
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

# --- Media Acquisition Stack ---
# Dedicated, isolated LXC for Sonarr/Radarr/Bazarr/SABnzbd/NZBHydra2, replacing the
# per-pod Mullvad kill-switch sidecar pattern in k3s with LXC-level network isolation.
# Modest footprint by design: config/app data only (root disk), bulk media remains on
# the existing NFS mount -- rpool is already at ~80% utilization (REL-005).
resource "proxmox_virtual_environment_container" "ct_srv_media_acq_01" {
  vm_id                 = 202
  node_name             = local.target_node
  tags                  = ["media", "acquisition", "vpn"]
  started               = true
  unprivileged          = true
  environment_variables = {}

  startup {
    order    = 5
    up_delay = 10
  }

  initialization {
    hostname = "ct-srv-media-acq-01"
    ip_config {
      ipv4 {
        address = "10.0.20.253/24"
        gateway = "10.0.20.1"
      }
    }
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
    swap      = 2048
  }

  features {
    nesting = true
  }

  disk {
    datastore_id = local.storage
    size         = 25
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "bc:24:11:41:9d:e2"
    vlan_id     = 20
    firewall    = true
  }

  operating_system {
    template_file_id = local.template
    type             = "debian"
  }

  # /dev/net/tun passthrough -- required for WireGuard (Mullvad) inside this
  # unprivileged container. Device is world-rw on the host (crw-rw-rw-, 10:200).
  device_passthrough {
    path       = "/dev/net/tun"
    uid        = 0
    gid        = 0
    mode       = "0666"
    deny_write = false
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

# --- DMZ Stack ---

resource "proxmox_virtual_environment_container" "ct_dmz_proxy_01" {
  vm_id                 = 301
  node_name             = local.target_node
  tags                  = ["dmz", "proxy", "network"]
  started               = true
  unprivileged          = true
  environment_variables = {}

  startup {
    order    = 6
    up_delay = 10
  }

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

# --- NFS Storage Stack ---

resource "proxmox_virtual_environment_container" "ct_srv_nfs_01" {
  vm_id        = 220
  node_name    = local.target_node
  tags         = ["nfs", "server", "storage"]
  started      = true
  unprivileged = false

  # Boots first (2026-06-20 boot-storm fix) — k3s nodes mount NFS-backed PVCs,
  # so storage must be up before the cluster starts. See docs/OPERATIONS.md.
  startup {
    order    = 1
    up_delay = 15
  }

  initialization {
    hostname = "ct-srv-nfs-01"
    ip_config {
      ipv4 {
        address = "10.0.20.100/24"
        gateway = "10.0.20.1"
      }
    }
    dns {
      servers = ["10.0.20.5", "10.0.20.2"]
    }
  }

  cpu {
    cores = 2
  }

  # 512MB was a near-miss: this LXC OOM-killed during a routine multi-directory
  # backup read across the SQLite apps it serves over NFS (2026-06-23), taking
  # down NFS for the whole cluster. Bumped with headroom — this is the storage
  # backend for nearly every nfs-client PVC in the cluster, not just its own data.
  memory {
    dedicated = 2048
    swap      = 1024
  }

  # Host bind mount holding every NFS-exported PVC. Never declared in
  # Terraform before (masked by the old ignore_changes = all) -- omitting it
  # would have meant destroy-and-recreate of this entire LXC on next apply.
  mount_point {
    volume    = "/nfs-data"
    path      = "/nfs-data"
    backup    = false
    replicate = true
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
    mac_address = "bc:24:11:95:b8:f3"
    vlan_id     = 20
    firewall    = true
  }

  operating_system {
    template_file_id = local.template
    type             = "debian"
  }

  # NFS CT holds live PVC data — ignore drift on fields that risk a destructive
  # recreate. memory is intentionally NOT ignored: it's safe to resize live and
  # needs to stay Terraform-managed after the 512MB incident above.
  lifecycle {
    ignore_changes = [
      description,
      initialization[0].user_account,
      operating_system[0].template_file_id,
      network_interface[0].mac_address,
      disk,
      features,
    ]
  }
}

resource "proxmox_virtual_environment_container" "ct_dmz_games_01" {
  vm_id                 = 302
  node_name             = local.target_node
  tags                  = ["dmz", "gaming"]
  started               = true
  unprivileged          = true
  environment_variables = {}

  startup {
    order    = 6
    up_delay = 10
  }

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
    dedicated = 16384
    swap      = 2048
  }

  features {
    nesting = true
  }

  disk {
    datastore_id = local.storage
    size         = 50
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
      features,
    ]
  }
}
