# Compute Nodes & Performance Tuning

This document details the compute hardware and the specific optimizations applied to ensure stability and efficiency across the infrastructure.

## 1. Proxmox Host (`pve-mgmt-01`)
| Component | Specification | Rationale |
| :--- | :--- | :--- |
| **CPU** | Ryzen 7 5725U | High core count for virtualization and container density. |
| **GPU** | Radeon Vega (iGPU) | Hardware acceleration for media services (e.g., Jellyfin, Immich). |
| **Storage A** | 512 GB NVMe | Fast local storage for OS and VMs. |
| **Storage B** | 2 TB External HDD | Dedicated USB 3.0 mount for Proxmox Backup Server. |

### Performance Tweaks (PVE)
- **CPU Scaling:** Governor set to `powersave` to reduce idle power consumption.
- **IOMMU:** Enabled (`amd_iommu=on`, `iommu=pt`) for direct GPU passthrough to LXC/VMs.
- **Hardware Offloading:** Enabled on the MikroTik trunk port (`ether5`) to offload L2 switching.

## 2. Raspberry Pi Cluster (High Availability)
| Component | Specification | Rationale |
| :--- | :--- | :--- |
| **Device** | 2x Raspberry Pi 4B | Low power consumption, perfect for 24/7 core network services. |
| **RAM** | 8 GB | Significant headroom for Docker stacks and in-memory databases. |
| **Storage** | 128 GB SD Card | Plenty of space for logs and local container volumes. |
| **Network** | 1 GbE Ethernet | Attached to MikroTik `ether6` and `ether7` (VLAN 20). |

### Operating System & Hardening
- **Distribution:** Raspberry Pi OS Lite (64-bit) based on Debian Bookworm.
- **Security:** Automatic security patches enabled via `unattended-upgrades`.
- **Docker:** Installed using the modern GPG-keyring method (`/etc/apt/keyrings`).

### HA Logic & Deployment
Managed via **Ansible** to ensure idempotency.
- **Keepalived (VRRP):** Manages Virtual IP `10.0.20.5`. If `rpi-srv-01` goes offline, the VIP migrates to `rpi-srv-02` ensuring zero downtime.
- **Services:** AdGuard Home (DNS sinkhole), Unbound (Recursive DNS), and Internal Nginx Proxy Manager.

### Performance Tweaks (RPi)
- **Radio Modules:** WiFi and Bluetooth disabled via `dtoverlay` in `/boot/config.txt`.
- **Memory Management:** ZRAM enabled via Ansible to reduce SD card wear-and-tear by using compressed RAM as swap.
