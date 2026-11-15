# pve_host_hardening

Patch management and SSH hardening for the Proxmox host (`pve_hosts`).

## What it does

- `unattended-upgrades` installs packages from the Debian security suite every
  day. It never reboots and never touches Proxmox packages.
- `/etc/ssh/sshd_config.d/00-hardening.conf`: key-only logins, root allowed with a
  key only (`prohibit-password`), no X11 forwarding, `MaxAuthTries 3`, and only
  `/root/.ssh/authorized_keys` (the pmxcfs-backed file) is read.
- Removes the older unmanaged `hardening.conf` drop-in and the unused
  `/root/.ssh/authorized_keys2` copy.

## Why Proxmox packages stay manual

`pve-manager`, `qemu-server`, `pve-cluster` and `proxmox-kernel-*` restart the API
and cluster daemons or need a reboot to take effect. They are upgraded by hand
(`apt full-upgrade`) in a planned window with VM snapshots, never by a timer. The
Proxmox repository's suite is `stable`, so the Debian security pattern cannot
match it by accident.

## Deploy

```bash
ansible-playbook ansible/site.yml --limit pve_hosts --tags pve_host_hardening --check --diff
ansible-playbook ansible/site.yml --limit pve_hosts --tags pve_host_hardening
```

Before the real run, hold an SSH session open
(`ssh -fN -M -S ~/.ssh/pve-hold root@10.0.10.10`) and confirm a fresh connection
works (`ssh -o ControlPath=none root@10.0.10.10 true`) before closing it.

## Rollback

From the held session, or from the Proxmox web shell or host console if SSH is
gone: `rm /etc/ssh/sshd_config.d/00-hardening.conf && systemctl reload ssh`.
To stop automatic upgrades: `rm /etc/apt/apt.conf.d/20auto-upgrades`.

## Verify

```bash
ssh root@10.0.10.10 'sshd -T | grep -E "passwordauth|permitroot|kbdinter"'
ssh root@10.0.10.10 'unattended-upgrade --dry-run -d 2>&1 | grep -i "allowed origins"'
# must fail with "Permission denied (publickey)"
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@10.0.10.10
```
