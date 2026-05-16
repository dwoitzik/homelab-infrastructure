# Compute Nodes & Architecture Strategy

## 1. Proxmox Host (`pve-mgmt-01`)
**Role:** Main Hypervisor & Heavy Workload Compute

| Component | Specification |
| :--- | :--- |
| **CPU** | AMD Ryzen 7 5825U (8C/16T, up to 4.5 GHz) |
| **RAM** | 64 GB DDR4 3200 MT/s (2x 32 GB) |
| **GPU** | AMD Radeon Vega iGPU (PCIe passthrough, IOMMU active) |
| **Storage A** | 512 GB NVMe — ZFS root (`rpool`), container & VM disks |
| **Storage B** | 2 TB External HDD (USB 3.0) — PBS backup datastore |
| **OS** | Proxmox VE — Debian Trixie (13), Kernel `7.0.0-3-pve` |

### VMs & Containers (`onboot`)

| ID | Hostname | Cores | RAM | Role |
| :--- | :--- | :--- | :--- | :--- |
| 110 | `ct-mgmt-pbs-01` | 2 | 2 GB | Proxmox Backup Server |
| 200 | `ct-srv-docker-01` | 4 | 4 GB | Legacy Docker workloads |
| 201 | `ct-srv-ai-01` | 8 | 32 GB | Ollama / LLM inference (GPU Passthrough) |
| 210 | `vm-srv-k3s-01` | 4 | 16 GB | K3s Primary Node (Core-Apps & Longhorn) |
| 301 | `ct-dmz-proxy-01` | 2 | 1 GB | DMZ reverse proxy (Public Facing) |
| 302 | `ct-dmz-games-01` | 4 | 4 GB | Game servers |

### Performance Tweaks

| Setting | Value | Note |
| :--- | :--- | :--- |
| CPU Governor | `powersave` | Reduces idle consumption |
| CPU C-States | Hardware default (C1/C2/C3) | `max_cstate=1` removed — caused PSU voltage spikes |
| IOMMU | Active (`amd_iommu=on`, `iommu=pt`) | GPU passthrough to LXC |
| Swap | 8 GB ZFS zvol (`rpool/swap`) | Safety net for LLM inference |
| ZFS ARC | Max ~6.2 GB (~10% RAM) | Default Proxmox cap |
| USB Storage | `nofail, device-timeout=5s` | USB dropout must not block boot/crash host |

---

## 2. Raspberry Pi Cluster (High Availability & Gateway)
**Role:** Out-of-Band Network Services & HA Ingress Layer

| Component | Specification |
| :--- | :--- |
| **Device** | 2× Raspberry Pi 4B |
| **RAM** | 8 GB |
| **Storage** | 128 GB SD Card |
| **Network** | 1 GbE — MikroTik `ether6`/`ether7` (VLAN 20) |
| **OS** | Raspberry Pi OS Lite 64-bit (Debian Bookworm) |

### Services (Gateway Strategy)

| Service | Details |
| :--- | :--- |
| **Keepalived (VRRP)** | VIP `10.0.20.5` — Fails over from `rpi-srv-01` to `rpi-srv-02` |
| **HAProxy / Traefik** | Ingress gateway routing TCP traffic to K3s backend |
| **AdGuard Home** | Primary DNS sinkhole |
| **Unbound** | Recursive DNS resolver |

### Performance Tweaks

| Setting | Value |
| :--- | :--- |
| WiFi & Bluetooth | Disabled via `dtoverlay` in `/boot/config.txt` |
| Swap | ZRAM (compressed RAM swap, reduces SD card wear) |
| Security patches | `unattended-upgrades` enabled |
