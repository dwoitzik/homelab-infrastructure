# Hardware — constraints that shape this architecture

This document exists so a future agent (or a future David) doesn't reintroduce a fix
for a problem this hardware doesn't have, or a regression for one it does.

## Inventory

| Node | Role | Spec |
|---|---|---|
| `pve-mgmt-01` | Proxmox host, sole physical compute node | Single box — everything else (VMs, LXCs) runs on it |
| `vm-srv-k3s-11` | k3s control-plane (sole server) | VM, boot disk on `local-lvm` |
| `vm-srv-k3s-12`, `vm-srv-k3s-13` | k3s workers | VMs, same storage |
| `rpi-srv-01`, `rpi-srv-02` | DNS/edge (AdGuard + Unbound, VRRP-paired via keepalived) | RPi 4B, SD card boot |
| Boot/VM-image storage | `local-lvm` (LVM-thin, VG `pve`) | **DRAM-less consumer NVMe.** No onboard write cache — every sustained write burst hits raw flash directly. |
| Bulk/archive storage | `media`/`archive` ZFS pool | HDD-backed, ample capacity, slow — used deliberately for anything that doesn't need low latency (PBS backups, staging large restores) |
| Immich photo library | USB-attached storage, NFS-exported | Untouched by k3s cluster lifecycle — physically independent |

## The hard constraint: the boot NVMe is DRAM-less

This is the single fact that shapes the most architecture decisions in this repo. A
DRAM-less SSD has no onboard cache to absorb write bursts or buffer the FTL's mapping
table — every write, including small/random ones, goes essentially straight to flash.
Sustained high write-amplification workloads on this specific drive cause real,
measured degradation (45% wear, 26.9TB lifetime writes as of the 2026-08-13 recovery's
own SMART check) and, at worst, host-level I/O stalls severe enough to cause application
crash loops.

**What this ruled out:**
- **etcd as the k3s datastore.** etcd's own fsync-heavy write pattern (a `fdatasync` on
  every raft commit) is close to a worst-case workload for this drive. This is why the
  cluster runs a single k3s server with the embedded SQLite datastore instead — see
  `docs/decisions/ADR-015-k3s-datastore-sqlite.md` for the full reasoning and the real
  incident history (REL-012c and others) that established this empirically, not just in
  theory.
- **ZFS for the boot/VM-image pool.** ZFS's copy-on-write model and its own write
  amplification (especially under `zvol`-backed VM disks) compounded the problem rather
  than helping it. Replaced with LVM-thin (`local-lvm`), a lighter-weight fit for this
  specific constraint — no copy-on-write overhead, simpler write path.
- **Longhorn for k8s storage.** Its own replication traffic is additional sustained
  write load this drive can't absorb well, on top of being architecturally redundant on
  an effectively single-host topology anyway. Storage classes are `local-path`
  (node-pinned, for small/latency-sensitive state) and `nfs-client` (for shared/larger
  state, backed by the NFS server LXC, not this NVMe).

**What's still allowed on this drive, deliberately:** SQLite-backed application state
(Vaultwarden, Headscale, Garage metadata, Uptime Kuma, Mealie, Open WebUI) — these have
a much lighter write pattern than etcd or ZFS's own metadata overhead, and moving them
elsewhere wasn't justified by any measured problem.

## Topology reality — this is not an HA cluster

`pve-mgmt-01` is a single point of failure for compute. There is no way to make this
genuinely zero-downtime with this hardware, and no configuration should pretend
otherwise. The actual design target is **fast, tested recovery**, not high availability
— every stateful component has a documented restore procedure (see per-service READMEs
under `kubernetes/apps/*/README.md` and `kubernetes/system/*/README.md`), backups are
proven restorable (not just scheduled), and the RTO/RPO this implies is measured in
minutes-to-hours for a full rebuild, not seconds of failover.

The two RPis are the one piece of real redundancy in this homelab: DNS (AdGuard +
Unbound) is VRRP-paired between them via keepalived, so losing either one individually
doesn't take down name resolution for the network. This was demonstrated live during the
2026-08-13 recovery (LEDGER Entry 45) — stopping the standby's DNS service had zero
impact on the network's actual resolution path, because the VIP stayed on the primary
throughout.

RPi SD cards are write-fragile — the same general class of concern as the boot NVMe, at
smaller scale. They run DNS/edge only, never databases or heavy logging. David has
ordered a USB-SATA adapter + SSD for `rpi-srv-02` to reduce this risk and potentially
support running a service independently of the main Proxmox host (e.g. Vaultwarden or
Headscale) — not yet arrived/actionable as of this writing.

## What NOT to do to this hardware

- Don't reintroduce etcd, ZFS on the boot pool, or Longhorn without a specific, measured
  reason that outweighs the write-amplification history above — "it's the more standard
  choice" is not sufficient justification given this drive's specific failure mode.
- Don't schedule heavy, bursty write workloads (large image pulls, ML model downloads,
  bulk backups) without considering contention — this recovery's own bulk 30-app
  ApplicationSet deploy caused several Postgres instances' `initdb` to get interrupted
  purely from simultaneous I/O contention, not a bug in any individual app.
- Don't put databases or write-heavy state on the Immich USB stick or the RPi SD cards —
  both are fine for their current, deliberately write-once/read-many or read-mostly
  roles, not for anything else.
