# ADR-073: SABnzbd scratch back on the archive HDD; 4K HDR releases without Remux

## Status

Accepted, 2026-11-11. Supersedes the tmpfs decision in
[ADR-066](ADR-066-tmpfs-for-sab-incomplete-downloads.md).

## Context

ADR-066 put SABnzbd's incomplete directory on a 10 GB host tmpfs. That caps every
in-flight download at 10 GB, which the ADR stated as the deliberate trade.

Radarr's quality profile did not respect that cap: it allowed 2160p Remux and
2160p Bluray releases of 50 to 80 GB. Such a job fills the tmpfs, SABnzbd pauses
itself with "Too little diskspace forcing PAUSE" and, with
`fulldisk_autoresume = 0`, never resumes. Aborted unpacks left `_UNPACK_*`
folders behind (about 27 GB found on 2026-11-11), and the queue needed manual
intervention.

The display is a 4K HDR TV with Dolby Vision and HDR10+. The visible gain of a
2160p release over 1080p is HDR, which 1080p releases almost never carry. A Remux
over a good 2160p encode adds bit-exact video and lossless audio at three to
four times the size, which the storage here cannot afford: the archive pool
holding media, PBS, Garage and the Immich mirror had about 240 GB free.

## Decision

1. **Incomplete downloads move back to the archive HDD**, as the ZFS dataset
   `archive/sab-incomplete` mounted at the same host path
   (`/mnt/sab-incomplete`), so the container's bind mount is unchanged. The
   disk is on USB 3 now, which removes the 5 MB/s unpack bottleneck that drove
   ADR-066. The tmpfs fstab entry is removed by the `pve_host_mounts` role.
2. **Radarr downloads 2160p HDR encodes, never Remux**: WEB 2160p and
   Bluray-2160p encodes, falling back to WEB/Bluray 1080p, with per-minute size
   limits so a typical film stays around 15 to 25 GB.
3. **Radarr refuses imports below a free-space floor** on `/media`, so 4K
   releases cannot fill the pool shared with backups.

## Consequences

- No 10 GB ceiling on a single job; unpack throughput is bound by the HDD.
- SABnzbd's scratch writes land on the HDD, not on RAM and not on the NVMe.
- LXC 202 no longer needs the 12 GB memory reservation sized for the tmpfs;
  lowering it is a separate Terraform change.
- Storage remains the limit for 4K: the pool fits only a modest number of new
  films until larger storage (a NAS) exists. The import floor fails safe by
  refusing imports rather than filling the pool.
