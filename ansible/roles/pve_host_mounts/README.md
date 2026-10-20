# pve_host_mounts

Host-level mounts on `pve-mgmt-01` that need to persist across reboots but
aren't part of Proxmox's own storage configuration. Kept in Ansible so they are
reproducible, not hand-edited into `/etc/fstab`.

## What it sets up

- `/mnt/sab-incomplete` — a 10 GB tmpfs holding SABnzbd's incomplete downloads.
  Bind-mounted into `ct-srv-media-acq-01` as `/downloads/incomplete`. See
  `docs/decisions/ADR-066-tmpfs-for-sab-incomplete-downloads.md`.

## Deploy

```sh
cd ansible && ansible-playbook site.yml --limit pve_hosts
```

## Notes

- `nosuid,nodev,nofail`; RAM-backed and reclaimable under pressure, but sized at
  20 GB against the host's headroom — keep an eye on it if the host gets tight.
- This is a host mount, distinct from `terraform/stacks/proxmox/lxc.tf`'s
  `mount_point` blocks, which expose it to the LXC.
