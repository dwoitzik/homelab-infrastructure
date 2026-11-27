# Runbook: rpi-srv-02 boots from its SSD, SD card as fallback

`rpi-srv-02` (Raspberry Pi 4B, Debian 13) runs its root filesystem from the USB SSD
instead of the SD card. The SD card stays in the slot, untouched and bootable, as the
fallback in the bootloader's boot order.

## Layout

| Partition | Size | Filesystem | Mounted at | Purpose |
|---|---|---|---|---|
| `sda1` | 95.3 GiB | ext4, UUID `82267fae-...` | `/mnt/ssd` | Data: Litestream replicas, standby data, Authelia Postgres standby, Immich mirror, kine copies |
| `sda2` | 512 MiB | vfat | `/boot/firmware` | Firmware, kernel, initramfs, `config.txt`, `cmdline.txt` |
| `sda3` | 16 GiB | ext4 | `/` | Root filesystem |
| `mmcblk0p1`, `mmcblk0p2` | SD card | vfat, ext4 | not mounted | Fallback boot and root, a snapshot of the root at cutover |

`sda1` keeps its PARTUUID and filesystem UUID, so the existing `/mnt/ssd` fstab line
works from either root.

## What keeps it that way (Ansible, `rpi_optimize`, host vars in `ansible/host_vars/rpi-srv-02.yml`)

- `rpi_optimize_eeprom_boot_order: "0xf14"`: USB mass storage first, then SD, then
  retry. The default `0xf41` would boot the SD card first.
- No initramfs change is needed: `usb-storage` and `uas` are built into the Raspberry Pi
  kernel (`CONFIG_USB_STORAGE=y`, `CONFIG_USB_UAS=y`), like the SD card driver.
- `rpi_optimize_usb_storage_quirks: ["152d:0583:u"]`: unchanged, applied to
  `/boot/firmware/cmdline.txt`, which is now the SSD's boot partition. It keeps the
  JMicron JMS583 bridge off UAS (it dropped off the bus under UAS on 2026-11-19).
- `rpi_optimize_ssd_mount`: the `/mnt/ssd` fstab entry.
- The Raspberry Pi Imager seed in `/boot/firmware/user-data` set `hostname: rpi-srv-01`
  (the card was imaged from the other Pi's settings), and cloud-init rewrites the
  `127.0.1.1` line of `/etc/hosts` from it on every boot. `rpi_optimize` now sets the
  seed's hostname to the inventory name. Before that, every reboot of this Pi left
  `sudo: unable to resolve host rpi-srv-02` until the next role run.

`root=PARTUUID=...` in `cmdline.txt` and the `/` and `/boot/firmware` fstab lines are
written once by the cutover below, not by Ansible: a role run while the Pi happens to be
on the SD fallback would otherwise rewrite the fallback to point at the SSD.

`RpiSrv02BootedFromSdCard` (critical) fires when `/` is on `mmcblk0p2` for 15 minutes.

## Rollback: boot from the SD card again

The SD card is never written after the cutover, so it boots the system as it was at
cutover time (older packages, AdGuard query log and Docker state from that moment; the
Litestream, Postgres standby and backup data live on `sda1` and are shared).

From a running SSD system (ssh `dw@10.0.20.3`):

```bash
sudo mount /dev/mmcblk0p1 /mnt/sdboot
cfg=$(mktemp); sudo rpi-eeprom-config | grep -v '^BOOT_ORDER=' > "$cfg"
echo BOOT_ORDER=0xf41 >> "$cfg"
sudo BOOTFS=/mnt/sdboot rpi-eeprom-config --apply "$cfg"
sudo umount /mnt/sdboot && sudo reboot
```

Remove `rpi_optimize_eeprom_boot_order` from the host vars in the same change, or the
next role run puts USB first again.

If the SSD system does not come up at all: the bootloader falls through to the SD card
by itself when the SSD's boot partition cannot be read. If it loads the SSD kernel but
the root fails, unplug the SSD (or its USB cable) and power-cycle: with no USB disk,
`0xf14` boots the SD card. Plug the SSD back in after the SD system is up; `/mnt/ssd`
mounts `nofail`, so mount it by hand (`sudo mount /mnt/ssd`) and restart the standby
services.

DNS is unaffected throughout as long as `rpi-srv-01` holds the VIP `10.0.20.5`.

## Cutover procedure (done once)

Preconditions: VIP on `rpi-srv-01`, `dig @10.0.20.2` answers, Alertmanager silence for
`instance=~"10.0.20.3.*"` and the standby alerts for the window.

1. Back up: partition table (`sgdisk --backup`), the SD boot partition, and the small
   SSD directories (`litestream-replicas`, `ha-standby`, `k3s-kine`) to the SD root.
2. Stop everything that writes to `/mnt/ssd` (`postgres-authelia-standby`), unmount it,
   `chattr +i /mnt/ssd` on the empty mount point so pushes from other hosts fail instead
   of landing on the SD card.
3. Shrink `sda1`: `e2fsck -f`, `resize2fs` below the target size, recreate partition 1
   with the same start sector and PARTUUID and the new end, add `sda2` (vfat, type
   `0700`) and `sda3` (ext4), grow `sda1`'s filesystem to fill the partition, `e2fsck -f`
   again, `chattr -i`, mount, start the standby.
4. Copy: bind-mount `/` and rsync it to `sda3` (`rsync -aHAXS --numeric-ids`), rsync
   `/boot/firmware` to `sda2`. On the copy: `/etc/fstab` gets the `sda2`/`sda3`
   PARTUUIDs, `sda2`'s `cmdline.txt` gets `root=PARTUUID=<sda3>`.
5. Test the root without touching the boot order: on the SD boot partition write
   `tryboot.txt` (a copy of `config.txt` plus `cmdline=cmdline-ssd.txt`) and
   `cmdline-ssd.txt` (`root=PARTUUID=<sda3>` plus `panic=10`). Stop Docker, tailscaled,
   keepalived and the standby, rsync once more with `--delete`, then
   `sudo reboot '0 tryboot'`. tryboot is one-shot: any failure and the next reset boots
   the SD card normally.
6. On the SSD root: check services. Then stage `BOOT_ORDER=0xf14` on the SD boot
   partition (`BOOTFS=/mnt/sdboot rpi-eeprom-config --apply`, the bootloader still reads
   the SD card first at that point) and reboot. The bootloader flashes the EEPROM, resets
   and boots from `sda2`.
7. Remove `tryboot.txt` and `cmdline-ssd.txt` from the SD card. Check-mode run of
   `site.yml --limit rpi-srv-02` must report no changes.

## Cutover record (2026-11-27)

| Step | Time | Result |
|---|---|---|
| `e2fsck -f` + `resize2fs` 111.8 GiB to 94 GiB, data partition offline | 12:23:12 to 12:27:04 | 75 GiB used, no errors; `/mnt/ssd` and the Postgres standby back at 12:27:10 |
| Warm copy of the SD root (7.2 GB) | 12:31:46 to 12:36:19 | |
| Quiesce, final sync, `reboot '0 tryboot'` | 12:36:34 to 12:37:10 | SD kernel, root on `sda3`, all services up |
| EEPROM 2025-05-08 to 2026-10-30 with `BOOT_ORDER=0xf14`, reboot | 12:39:08 to 12:39:33 | booted from `sda2`/`sda3` |

`rpi-srv-02` was down twice for about 40 seconds; `rpi-srv-01` held the VIP throughout.
After the first reboot the 10.0.20.0/24 route's primary moved to `homelab-router-1` (the
in-cluster subnet router) and headscale keeps it there until that node goes away; both
nodes have the route approved, so tailnet clients were not affected.

The shrink left `/mnt/ssd` at 85 % (15 GB free); `ImmichMirrorSSDFull` fires at 90 %.
`/mnt/ssd` on the SD root held two empty `immich-library/snapshots` directories created
by a backup push while the SSD was off the bus on 2026-11-19. The empty mount point on
the SSD root is now immutable (`chattr +i`, set through `mount --bind / /mnt/oldroot`),
so a push while `/mnt/ssd` is not mounted fails instead of filling the root filesystem.

## Checks after any reboot

```bash
findmnt / /boot/firmware /mnt/ssd                 # sda3, sda2, sda1
sudo rpi-eeprom-config | grep BOOT_ORDER          # 0xf14
cat /sys/module/usb_storage/parameters/quirks     # 152d:0583:u
lsusb -t | grep 'Mass Storage'                    # Driver=usb-storage, not uas
grep 127.0.1.1 /etc/hosts                         # rpi-srv-02
dig +short github.com @10.0.20.3
systemctl is-active keepalived postgres-authelia-standby tailscaled docker
```
