# ADR-066: tmpfs for SABnzbd's incomplete downloads

## Status

Accepted and applied, 2026-10-19.

## Context

SABnzbd (in `ct-srv-media-acq-01`) writes every download into an *incomplete*
directory while it is being fetched and unpacked, then moves the finished files
to the library. That directory is pure transient scratch: its contents are
discarded the moment a download completes or fails.

It has already moved twice for I/O reasons:

- **Off rpool.** On the root SSD pool, SABnzbd's high-rate writes polluted ZFS
  dirty data shared with the k3s VM zvols, delaying txg commits enough to blow
  etcd lease timeouts — a real k3s crash (REL-020).
- **Onto the archive HDD** (the 2 TB USB disk). That fixed etcd, but made the
  HDD's random I/O the bottleneck: parallel download + verify + unpack thrashed
  a spinning disk also serving the media library, and unpack throughput sat
  around 5 MB/s.

## Decision

**Put the incomplete directory on a 20 GB host tmpfs**, `/mnt/sab-incomplete`,
bind-mounted into the LXC at `/downloads/incomplete`. Sustained unpack throughput
rose from ~5 MB/s to ~30 MB/s, and the archive HDD is left to the library.

The mount lives in `/etc/fstab` and is now managed by the `pve_host_mounts`
Ansible role (previously a manual edit). Options: `size=20G,mode=0755,nosuid,nodev,nofail`.

## Consequences

- **Transient data, lost on reboot — by design.** A reboot mid-download loses only
  partial downloads, which SABnzbd re-fetches. Nothing durable lives here.
- **It is RAM.** tmpfs pages count against the host's 62 GB and are reclaimable
  under pressure (evictable, like page cache), so the 20 GB cap is a ceiling, not
  a reservation — but a large in-flight download can still compete with the k3s
  VMs. Sized against current headroom; revisit if the host gets tight.
- **The LXC's bind-mount source is ForceNew in Terraform.** `mount_point.volume`
  cannot be changed in place, so `ct_srv_media_acq_01` now ignores drift on
  `mount_point` (same pattern as the NFS LXC) to prevent an accidental
  destroy-and-recreate of the whole media stack.

## Alternatives considered

- **A dedicated LV/partition for incomplete downloads** — more durable, but this
  data doesn't need durability, and it would add another I/O path to a
  DRAM-less NVMe pool. tmpfs is simpler and faster for exactly this use case.
- **Leave it on the archive HDD** — safe for etcd, but the unpack bottleneck
  stayed, and it contends with media reads.
