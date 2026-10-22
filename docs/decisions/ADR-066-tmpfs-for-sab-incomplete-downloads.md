# ADR-066: tmpfs for SABnzbd's incomplete downloads

## Status

Accepted and applied, 2026-10-19. Revised 2026-10-20 after a production
incident (see "Revised sizing and the memory-cgroup rule" below).

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
  around 5 MB/s. (The disk was still on a USB-2 port at the time; it has since
  moved to USB-3, which is worth re-measuring if this decision is revisited.)

## Decision

**Put the incomplete directory on a 10 GB host tmpfs**, `/mnt/sab-incomplete`,
bind-mounted into the LXC at `/downloads/incomplete`, with the container's
memory limit sized to sit above it.

The mount lives in `/etc/fstab` and is managed by the `pve_host_mounts` Ansible
role (previously a manual edit). Options:
`size=10G,mode=0755,nosuid,nodev,nofail`.

`ct_srv_media_acq_01` reserves 12 GB (`memory.dedicated = 12288`, plus 4 GB
swap) for exactly this reason.

## Revised sizing and the memory-cgroup rule

The first version of this decision used a 20 GB tmpfs and left the container at
its old 4 GB limit. That combination took the host down.

tmpfs pages are **shmem**, and shmem is charged to the memory cgroup of the
process that writes it — that is, to LXC 202, *not* to the host's free-running
pool. A ramdisk therefore does not give a container free memory; it consumes the
container's own budget, and once that budget is gone the kernel's answer is not
"evict host page cache" but "reclaim inside the cgroup, then throttle".

What that looked like: one 8.9 GB Blu-ray rip filled the tmpfs well past the
container's 4 GB limit, the kernel logged ~8 million `memory.high` throttle
events, and roughly 130 threads (the whole media stack, plus Enshrouded's game
process competing on the same node) parked in uninterruptible sleep in
`folio_wait_bit_common` → `filemap_fault` on those tmpfs pages. Host load sat
near 150 and `memory.pressure` for the container reported `full avg10=14.36`.
Nothing was out of memory, no OOM was recorded, and the job completed fine — the
host was simply stuck servicing reclaim. Raising the container to 12 GB and
capping the ramdisk at 10 GB cleared it immediately.

The rule that follows, and the reason the two numbers are coupled in the
comments above:

1. **The tmpfs cap must be strictly below the container's memory limit** — the
   gap is the stack's own anonymous + page-cache usage (~2 GB measured).
2. **The tmpfs cap is also the maximum size of any single in-flight download.**
   A larger NZB will stall at the cap. That is the deliberate trade: a ramdisk
   big enough for an arbitrary 4K remux does not exist on a 62 GB host. If
   bigger jobs need to work, the incomplete directory has to move back to a
   block device — the HDD is the candidate now that it is on USB-3, and that
   trade is unpack throughput vs. no size ceiling.

Measured on the 10 GB/12 GB sizing: an 8.9 GB job unpacked in 151 s
(~59 MB/s), which is now bound by the HDD's sequential write into the complete
directory rather than by the read out of RAM.

## Consequences

- **Transient data, lost on reboot — by design.** A reboot mid-download loses
  only partial downloads, which SABnzbd re-fetches. Nothing durable lives here.
- **The container carries the ramdisk, not the host.** This is the opposite of
  what the first draft of this ADR claimed. The host's 62 GB is not what
  bounds the download; the container's 12 GB is, and the LXC-sum soft check in
  `scripts/check-host-memory-overcommit.py` (warn-only) should be re-read
  before either number grows.
- **The LXC's bind-mount source is ForceNew in Terraform.** `mount_point.volume`
  cannot be changed in place, so `ct_srv_media_acq_01` ignores drift on
  `mount_point` (same pattern as the NFS LXC) to prevent an accidental
  destroy-and-recreate of the whole media stack. The container's memory limit is
  *not* ignored, so changing it lands as an in-place update.

## Alternatives considered

- **A dedicated LV/partition for incomplete downloads** — more durable, and it
  removes both the size ceiling and the memory-cgroup coupling. Rejected for
  now because it adds another I/O path to a DRAM-less NVMe pool already at 76%
  of its rated endurance, and the unpack win over a USB-3 HDD is smaller than
  it once was. Revisit if downloads regularly exceed ~10 GB.
- **Leave it on the archive HDD** — the safe default, and the option to fall
  back to. It was rejected on throughput grounds while the disk was still on
  USB-2; that premise no longer holds and should be re-tested before this ADR is
  changed again.
