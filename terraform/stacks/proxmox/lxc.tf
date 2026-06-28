locals {
  target_node = "pve-mgmt-01"
  storage     = "local-zfs"
  template    = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}

# --- Management Stack ---

# REL-016: onboot=1 is applied manually (`pct set 110 -onboot 1`) and NOT via
# Terraform's start_on_boot attribute -- confirmed live that bpg/proxmox 0.100.0
# doesn't read this attribute back from the API into state, so any value set
# here always shows as "No changes" regardless of the live onboot value,
# silently not applying. Same gap on ct_srv_docker_01/ct_srv_ai_01/
# ct_dmz_proxy_01/ct_dmz_games_01 below. If any of these containers are ever
# recreated, onboot needs to be set manually again afterward.
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

# REL-016: onboot=1 applied manually, see ct_mgmt_pbs_01's comment above.
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

# REL-016: onboot=1 applied manually, see ct_mgmt_pbs_01's comment above.
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

  # REL-012/REL-016: reduced from 8 to 6 of the host's 16 logical threads -- a
  # CPU-only Ollama inference run (gemma2:27b, ~18GB) previously had no
  # ceiling here, took 17+ minutes, and froze the entire host (every other
  # LXC/VM on mini, confirmed unreachable at the SSH-banner level, needed a
  # manual power-cycle). Proxmox doesn't isolate CPU between LXCs by default.
  # This `cores` reduction is the durable, Terraform-tracked half of the fix;
  # bpg/proxmox 0.100.0's container resource has no `limit` attribute at all
  # (confirmed via the provider's own schema: cpu{} only exposes
  # architecture/cores/units) -- Proxmox's actual cpulimit (a fractional
  # ceiling, not just a core count) is applied manually via
  # `pct set 201 -cpulimit 6` and is NOT representable here. If this
  # container is ever recreated, that manual step needs to be redone.
  cpu {
    cores = 6
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

  # Media library bind-mount: /mnt/media is a local ZFS dataset (archive
  # pool) on this same Proxmox host -- the NFS export to k8s pods is
  # incidental, the host itself doesn't need NFS to reach its own disk.
  # Mounting NFS *from inside* this unprivileged LXC fails with EPERM
  # regardless of the mount=nfs feature flag (confirmed live: a deeper
  # unprivileged-userns kernel restriction, not an AppArmor/seccomp gap --
  # showmount/RPC queries succeed fine, ruling out a network/export-ACL
  # problem), so this native bind-mount sidesteps NFS entirely instead.
  mount_point {
    volume = "/mnt/media"
    path   = "/media"
  }

  # /dev/net/tun passthrough -- required for gluetun (Mullvad WireGuard)
  # inside this unprivileged container; without it Docker can't bind-mount
  # the device into the gluetun container at all ("error gathering device
  # information... no such file or directory", confirmed live). Couldn't be
  # declared at container-creation time (Atlantis's Terraform API token isn't
  # root@pam, and Proxmox only allows device_passthrough on CREATE for
  # root@pam) -- added manually via root SSH after the container existed
  # (`pct set 202 -dev0 ...`), now declared here to match and avoid drift,
  # same pattern as the AI LXC's GPU passthrough below.
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

# --- Jellyfin Stack ---
# Dedicated LXC for hardware-transcoded Jellyfin, replacing the software-only k3s
# Deployment. Needs the same AMD Vega iGPU (VAAPI render node) as ct-srv-ai-01's
# ROCm passthrough -- both share mini's one APU; /dev/dri/renderD128 supports
# concurrent access from multiple processes/containers fine (it's just a DRM render
# node, not an exclusive lock). Modest footprint by design: config/Docker layers
# only on the root disk, bulk media stays on the existing /mnt/media ZFS dataset via
# a native bind-mount (same pattern as ct-srv-media-acq-01) -- rpool is already at
# ~80% utilization (REL-005).
resource "proxmox_virtual_environment_container" "ct_srv_jellyfin_01" {
  vm_id                 = 203
  node_name             = local.target_node
  tags                  = ["jellyfin", "media", "gpu"]
  started               = true
  unprivileged          = true
  environment_variables = {}

  startup {
    order    = 5
    up_delay = 10
  }

  initialization {
    hostname = "ct-srv-jellyfin-01"
    ip_config {
      ipv4 {
        address = "10.0.20.254/24"
        gateway = "10.0.20.1"
      }
    }
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
    swap      = 1024
  }

  features {
    nesting = true
  }

  disk {
    datastore_id = local.storage
    size         = 15
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "bc:24:11:6f:1a:c9"
    vlan_id     = 20
    firewall    = true
  }

  operating_system {
    template_file_id = local.template
    type             = "debian"
  }

  # Media library bind-mount -- added manually via root SSH (pct set 203 -mp0
  # ...) once the container existed, since "mount point type bind" can't be
  # configured at create time via Atlantis's non-root@pam token. Declared here
  # to match and avoid drift.
  mount_point {
    volume = "/mnt/media"
    path   = "/media"
  }

  # NVMe-backed Jellyfin cache (transcodes + image extraction). ZFS dataset
  # rpool/jellyfin-cache (20 G quota). Added via pct set 203 -mp1. Owner must
  # be host uid 100000 (= LXC root via Proxmox default subuid mapping).
  mount_point {
    volume = "/rpool/jellyfin-cache"
    path   = "/jellyfin-cache"
  }

  # /dev/dri/renderD128 passthrough (VAAPI hardware transcode) -- same story,
  # added manually (pct set 203 -dev0 ...) once the container existed.
  device_passthrough {
    path       = "/dev/dri/renderD128"
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

# --- DMZ Stack ---

# REL-016: onboot=1 applied manually, see ct_mgmt_pbs_01's comment above.
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

  # REL-019: Garage's bulk S3 data (115GB+) was found living on rpool via the
  # /nfs-data mount above, despite CLAUDE.local.md stating the archive pool
  # (this host's 2TB USB HDD) is the intended Garage/backup target -- the
  # most likely dominant contributor to the chronic disk I/O contention
  # behind REL-005/REL-012/REL-016/REL-019. A second mount_point block here
  # to expose an archive-pool dataset for the migration was attempted and
  # rejected: bpg/proxmox 0.100.0's mount_point.volume is ForceNew, so ANY
  # change to the set of mount_point blocks (not just editing an existing
  # one) replaces the entire container -- confirmed via a real `terraform
  # plan` showing "1 to add, 0 to change, 1 to destroy" for this LXC, which
  # serves NFS for nearly every PVC in the cluster. Applied manually instead:
  # `pct set 220 -mp1 /mnt/pbs-storage/garage-data,mp=/archive-garage-data`.
  # `pct set 220 -mp2 /mnt/pbs-storage/immich-library,mp=/archive-immich-library`.
  # If this container is ever recreated, both manual steps need to be redone
  # (same category of gap as the onboot/cpulimit notes elsewhere in this file).
  # Note: if pct set fails with "Input/output error", check for stale migration
  # lock files in /run/lock/pve-manager/ and remove them, then restart pve-cluster.

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
  # mount_point added 2026-06-25 (REL-019): without this, Terraform sees the
  # manually-added archive-pool mount (mp1, not declared above) as drift and
  # plans to remove it -- but mount_point.volume is ForceNew, so "removing"
  # it via Terraform would ALSO destroy-and-recreate this LXC. Confirmed live
  # via `terraform plan` before this was added (showed "1 to destroy").
  lifecycle {
    ignore_changes = [
      description,
      initialization[0].user_account,
      operating_system[0].template_file_id,
      network_interface[0].mac_address,
      disk,
      features,
      mount_point,
    ]
  }
}

# REL-016: onboot=1 applied manually, see ct_mgmt_pbs_01's comment above.
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
# Trigger fresh atlantis plan (media-acq LXC apply pending)
