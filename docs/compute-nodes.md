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

| Hostname | Type | Cores | RAM | Role |
| :--- | :--- | :--- | :--- | :--- |
| `ct-mgmt-pbs-01` | LXC | 2 | 2 GB | Proxmox Backup Server |
| `ct-srv-docker-01` | LXC | 4 | 4 GB | Legacy Docker workloads |
| `ct-srv-ai-01` | LXC | 8 | 32 GB | Ollama / LLM inference (GPU Passthrough) |
| `ct-srv-nfs-01` | LXC | 2 | 1 GB | NFS storage server (ZFS-backed, `nfs-client` StorageClass for all k3s PVCs) |
| `vm-srv-k3s-11` | VM | 4 | 12 GB | k3s control-plane + embedded etcd (1 of 3, HA) |
| `vm-srv-k3s-12` | VM | 4 | 16 GB | k3s control-plane + embedded etcd (1 of 3, HA) |
| `vm-srv-k3s-13` | VM | 4 | 16 GB | k3s control-plane + embedded etcd (1 of 3, HA) |
| `ct-dmz-proxy-01` | LXC | 2 | 1 GB | DMZ reverse proxy (Public Facing) |
| `ct-dmz-games-01` | LXC | 4 | 12 GB | Game servers (bumped from 4 GB after Cobblemon lag investigation, 2026-06) |

All three k3s nodes run as control-plane with embedded etcd (migrated from single-node
SQLite, 2026-06) — there is no single "primary" node anymore. API access is via a
Keepalived VIP (`10.0.20.10`), health-checked against `systemctl is-active k3s`.
Longhorn was removed in the same migration; all PVCs now use the `nfs-client`
StorageClass backed by `ct-srv-nfs-01`.

### Performance Tweaks

| Setting | Value | Note |
| :--- | :--- | :--- |
| CPU Governor | `powersave` | Reduces idle consumption |
| CPU C-States | Hardware default | Tried `max_cstate=1 idle=nomwait` as a suspected fix for repeated host freezes (2026-06-20), reverted — pushed idle temps to 96°C. Real cause was depleted thermal paste, fixed by repaste. |
| IOMMU | Active (`amd_iommu=on`, `iommu=pt`) | GPU passthrough to LXC |
| Swap | 8 GB ZFS zvol (`rpool/swap`) | Safety net for LLM inference |
| ZFS ARC | Capped at 8 GB (`zfs_arc_max`) | Was unbounded (up to ~50% RAM); capped after it competed with VM memory during boot |
| USB Storage | `nofail, device-timeout=5s` | USB dropout must not block boot/crash host |
| VM/LXC `onboot` startup order | Staggered (NFS first, then k3s nodes 30s apart, then the rest) | Fixes a boot-time resource storm that hit load average 147 within 4 min (2026-06-20) |

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

### Resilience & Security (2026-06-21 hardening pass)

These RPis are physical hardware running DNS for the whole house — no PBS/Velero coverage
(those only reach VMs/LXCs), so every protection here is self-contained on the device.

| Component | Detail |
| :--- | :--- |
| Hardware watchdog | BCM overlay + systemd `RuntimeWatchdogSec=15s` — self-heals from a total kernel freeze, not just a crashed container |
| Host firewall | `nftables`, additive `inet hostfw` table — default-drop INPUT, only covers natively-bound services (SSH, AdGuard via `network_mode: host`, VRRP); deliberately does not touch Docker's own iptables-nft tables |
| fail2ban | sshd jail, 5 attempts / 10 min → 1h ban |
| Independent DNS healthcheck | systemd timer, every 2 min, posts to Discord only on state change — zero dependency on the k3s/Prometheus stack |
| Local config backup | systemd timer, daily 02:30, 14-snapshot retention of AdGuard/Unbound config |
| Docker log limits | `max-size: 10m, max-file: 3` daemon-wide — unbounded json-file logs were a real disk-fill risk on SD storage |
| Per-container memory limits | Set on every RPi Docker workload |
