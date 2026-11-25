# pve_host_mounts

Host-level mounts on `pve-mgmt-01` that need to persist across reboots but
aren't part of Proxmox's own storage configuration. Kept in Ansible so they are
reproducible, not hand-edited into `/etc/fstab`.

## What it sets up

- `archive/sab-incomplete` at `/mnt/sab-incomplete`: SABnzbd's incomplete downloads,
  bind-mounted into `ct-srv-media-acq-01` as `/downloads/incomplete` (ADR-073 replaced
  the earlier tmpfs from ADR-066).
- `archive/jellyfin-cache` at `/mnt/jellyfin-cache` (20 G quota): Jellyfin's cache,
  bind-mounted into `ct-srv-jellyfin-01` as `/jellyfin-cache`. It must stay outside
  `/mnt/pbs-storage`, the PBS datastore: garbage collection walks every directory
  there and aborts on the cache's 0700 shader directories.

## Deploy

```sh
cd ansible && ansible-playbook site.yml --limit pve_hosts
```

## Notes

- `nosuid,nodev,nofail`; RAM-backed and reclaimable under pressure, but sized at
  20 GB against the host's headroom — keep an eye on it if the host gets tight.
- This is a host mount, distinct from `terraform/stacks/proxmox/lxc.tf`'s
  `mount_point` blocks, which expose it to the LXC.
