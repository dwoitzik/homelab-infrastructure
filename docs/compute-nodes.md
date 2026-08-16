# Compute Nodes & Architecture Strategy

## 1. Proxmox Host (`pve-mgmt-01`)

**Role:** Main Hypervisor & Heavy Workload Compute

| Component | Specification |
| :--- | :--- |
| **CPU** | AMD Ryzen 7 5825U (8C/16T, up to 4.5 GHz) |
| **RAM** | 64 GB DDR4 3200 MT/s (2x 32 GB) |
| **GPU** | AMD Radeon Vega iGPU (PCIe passthrough, IOMMU active) |
| **Storage A** | 512 GB NVMe — LVM-thin (`local-lvm`, VG `pve`), container & VM disks. Migrated off ZFS (`rpool`) 2026-08-13 disaster recovery; `rpool` no longer exists on this host. |
| **Storage B** | 2 TB External HDD (USB 3.0) — ZFS pool `archive` (single vdev). PBS backup datastore plus bulk/archive storage generally (Jellyfin cache, media staging) — no longer PBS-only. |
| **OS** | Proxmox VE — Debian Trixie (13), Kernel `7.0.0-3-pve` |

### VMs & Containers (`onboot`)

Table re-verified against `terraform/stacks/proxmox/{lxc,vm}.tf` directly
(cores/`dedicated` memory) -- several values here had drifted from what's actually
defined, and 3 LXCs added since the initial pass (`ct-srv-media-acq-01`,
`ct-srv-jellyfin-01`, `ct-srv-atlantis-01` -- see ADR-012) were missing entirely.

| Hostname | Type | Cores | RAM | Role |
| :--- | :--- | :--- | :--- | :--- |
| `ct-mgmt-pbs-01` | LXC | 2 | 2 GB | Proxmox Backup Server |
| `ct-srv-docker-01` | LXC | 4 | 4 GB | Legacy Docker workloads |
| `ct-srv-ai-01` | LXC | 6 | 32 GB | Ollama / LLM inference (GPU Passthrough) -- cores cut from 8 after host CPU overcommit |
| `ct-srv-nfs-01` | LXC | 2 | 2 GB | NFS storage server (`/nfs-data` bind-mount, backed by the host's `local-lvm` root disk — not ZFS; the container's own root disk is on `local-lvm` too. `nfs-client` StorageClass for all k3s PVCs) |
| `ct-srv-media-acq-01` | LXC | 2 | 4 GB | Media acquisition stack (Mullvad-wrapped, ADR-010) |
| `ct-srv-jellyfin-01` | LXC | 2 | 2 GB | Jellyfin (GPU-passthrough hardware transcode) |
| `ct-srv-atlantis-01` | LXC | 2 | 2 GB | Atlantis GitOps runner (moved off k3s, ADR-012) |
| `vm-srv-k3s-11` | VM | 4 | 12 GB | k3s control-plane + embedded etcd (sole server) |
| `vm-srv-k3s-12` | VM | 4 | 8 GB | k3s agent (worker only, no etcd) |
| `vm-srv-k3s-13` | VM | 4 | 8 GB | k3s agent (worker only, no etcd) |
| `ct-dmz-proxy-01` | LXC | 2 | 1 GB | DMZ reverse proxy (Public Facing) |
| `ct-dmz-games-01` | LXC | 2 | 8 GB | Game servers -- cores cut from 4, memory right-sized to 8GB after observing a ~4.7GB peak |

`vm-srv-k3s-11` is the sole control-plane + etcd server; `vm-srv-k3s-12` and `-13` are
agent (worker) nodes only. A 3-node embedded-etcd HA setup was tried and reverted — all
three VMs share the same physical host and disk (originally the ZFS boot pool, now
`local-lvm` post-migration — the contention is about the single physical NVMe either
way), so a 3-writer etcd quorum produced enough concurrent I/O to freeze the host (the
same failure mode as the ZFS tuning above, just from a different source). Single-etcd plus agent workers gives the compute capacity
of 3 VMs without the multi-writer etcd I/O storm. This is not HA for the control plane —
`mini` remains a single point of failure either way — so the only real mitigation is fast
recovery from Git + backups, not uptime. RPis are intentionally excluded from k3s entirely
(SD cards can't take etcd/database write load). PVCs use the `nfs-client` StorageClass
backed by `ct-srv-nfs-01`.

### Performance Tweaks

| Setting | Value | Note |
| :--- | :--- | :--- |
| CPU TDP | 25W (BIOS, down from 54W default) | BMAX ships an undersized PSU for this chip's rated TDP — repeated freezes traced to power delivery, not the CPU die itself |
| CPU Governor | `powersave` | Reduces idle consumption |
| CPU C-States | Hardware default | Tried `max_cstate=1 idle=nomwait` as a guess at fixing repeated host freezes, made idle temps worse (96°C), reverted. Not the cause. |
| PCIe ASPM | `performance` (forced via `pcie_aspm=off` + live policy switch) | Power-saving PCIe link states were a candidate cause of NVMe stalls under load, given the marginal PSU |
| IOMMU | Active (`amd_iommu=on`, `iommu=pt`) | GPU passthrough to LXC |
| Swap | 8 GB LVM logical volume (`pve/swap`) | Safety net for LLM inference. No longer a ZFS zvol — moved with the rest of boot/VM storage off `rpool` in the 2026-08-13 migration. |
| ZFS version | 2.4.2-pve1 (upgraded from 2.4.1-pve1, 2026-06-22) | 2.4.1 has a known unfixed deadlock under ARC memory pressure + concurrent I/O (`openzfs/zfs#18426`) matching every freeze symptom seen here exactly: ARC pinned at max, I/O worker threads idle-waiting, no kernel panic trace. Still relevant — the `archive` pool below is still ZFS. |
| ZFS ARC | `zfs_arc_min=4GB` / `zfs_arc_max=16GB` (`/etc/modprobe.d/zfs.conf`, live-verified) | **Loosened, not tightened, post-migration.** The aggressive 4 GB cap below was defensive tuning for ZFS sharing the DRAM-less boot NVMe with etcd; ZFS now only backs the slower, latency-tolerant `archive` HDD pool, so a larger cache is a straightforward win with none of the original contention risk. Historical value for reference: was capped at 4 GB (down from an 8 GB default) while `rpool` was still the boot pool. |
| ZFS dirty data | `zfs_dirty_data_max` at the OpenZFS default (4 GB, live-verified) — no longer overridden | Was capped at 1 GB while ZFS backed the boot NVMe (forced smaller, more frequent flushes to avoid write-behind stalls). That override isn't present in `/etc/modprobe.d/` anymore; the HDD-backed `archive` pool doesn't have the same DRAM-less-NVMe latency sensitivity, so the default is fine. |
| ZFS txg timeout | 5s (`zfs_txg_timeout`, live-verified) — same value as before, but now just the OpenZFS default rather than a deliberate override | Originally tuned down from 15s for the same NVMe-latency reasons as the dirty-data cap; happens to already equal the current default, so no functional change either way. |
| USB Storage | `nofail, device-timeout=5s` | USB dropout must not block boot/crash host |
| VM/LXC `onboot` | **Enabled (`onboot=1`) for every VM/LXC** (re-verified live via `pvesh get .../config`) | Originally disabled for isolated debugging during a host-freeze investigation, then reversed once that need passed -- control-plane VMs, PBS, and several LXCs had failed to auto-recover after a real host freeze while this was off. `bpg/proxmox`'s LXC resource doesn't reliably manage this attribute (`terraform plan` always shows "No changes" regardless of live value), so it's applied manually (`pct set <id> -onboot 1`) and needs reapplying if a container is ever recreated. |

---

## 2. Raspberry Pi Cluster (High Availability DNS)

**Role:** Out-of-Band Network Services — Highly-Available DNS

| Component | Specification |
| :--- | :--- |
| **Device** | 2× Raspberry Pi 4B |
| **RAM** | 8 GB |
| **Storage** | 128 GB SD Card |
| **Network** | 1 GbE — MikroTik `ether6`/`ether7` (VLAN 20) |
| **OS** | Raspberry Pi OS Lite 64-bit (Debian Bookworm) |

### Services (DNS Strategy)

| Service | Details |
| :--- | :--- |
| **Keepalived (VRRP)** | VIP `10.0.20.5` — Fails over from `rpi-srv-01` to `rpi-srv-02` |
| **AdGuard Home** | Primary DNS sinkhole (blocks ads/trackers, PTR forwarding for `192.168.178.0/24` only) |
| **Unbound** | Recursive DNS resolver (root-hints, prefetch, DNSSEC) |

Ingress for k3s-hosted services is unrelated to this layer: MetalLB assigns LoadBalancer
IPs and Traefik (running inside k3s) terminates and routes that traffic. The RPis are not
on the ingress path — they exist solely to serve DNS for the network.

### Performance Tweaks

| Setting | Value |
| :--- | :--- |
| WiFi & Bluetooth | Disabled via `dtoverlay` in `/boot/config.txt` |
| Swap | ZRAM (compressed RAM swap, reduces SD card wear) |
| Security patches | `unattended-upgrades` enabled |

### Resilience & Security (2026-06-21 hardening pass)

These run DNS for the whole house and PBS/Velero only cover VMs/LXCs, not physical
hardware. So everything here is self-contained on the device itself.

| Component | Detail |
| :--- | :--- |
| Hardware watchdog | BCM overlay + systemd `RuntimeWatchdogSec=15s`. Recovers from a total kernel freeze, not just a crashed container. |
| Host firewall | `nftables`, additive `inet hostfw` table, default-drop INPUT. Only covers natively-bound services (SSH, AdGuard since it's `network_mode: host`, VRRP) — doesn't touch Docker's own iptables-nft tables on purpose. |
| fail2ban | sshd jail, 5 attempts / 10 min → 1h ban |
| Independent DNS healthcheck | systemd timer every 2 min, posts to Discord only on state change. No dependency on k3s/Prometheus. |
| Local config backup | systemd timer, daily 02:30, keeps 14 snapshots of AdGuard/Unbound config |
| Docker log limits | `max-size: 10m, max-file: 3` daemon-wide — unbounded logs were eating disk on SD storage |
| Per-container memory limits | Set on every RPi Docker workload |
