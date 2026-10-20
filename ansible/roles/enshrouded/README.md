# enshrouded

Enshrouded dedicated server (SteamCMD app `2278520`) on the DMZ game LXC
(`ct-dmz-games-01`, VLAN 30, `10.0.30.3`). Windows-only binary, run under Wine
via a `systemd` unit. See `docs/decisions/ADR-065-enshrouded-dedicated-server.md`.

## What it sets up

- Wine (`wine`, `wine32:i386`, `wine64`) plus `xvfb` — the server expects a
  display even headless.
- SteamCMD from the official Valve tarball (`/opt/steamcmd`); the Debian
  `steamcmd` package needs non-free, which this host does not enable.
- The **Windows** depot: `+@sSteamCmdForcePlatformType windows` is required, or
  SteamCMD fetches ~100 MB of Linux libs and reports success with no executable.
- `/home/enshrouded/enshroudedserver` (install), `enshrouded_server.json`, and a
  `Restart=on-failure` unit running
  `xvfb-run -a wine enshrouded_server.exe`.
- Daily cron: `savegame/` backup (14-day local retention) at 04:30, restart at
  05:00. The whole LXC rootfs is also captured by the nightly PBS job → R2, so the
  local copies are the fast-restore path, not the only backup.
- Weekly cron (Wed 04:00): SteamCMD `+app_update ... validate`, then restart.
- ufw allow for UDP 15636/15637 when ufw is active.

## Deploy

```sh
cd ansible && ansible-playbook site.yml --limit dmz_games
```

## Operate

```sh
systemctl status enshrouded
journalctl -u enshrouded -f
tail -f /home/enshrouded/enshroudedserver/logs/enshrouded_server.log   # "HostOnline" = up
ss -lunp | grep 15637
```

Config lives at `/home/enshrouded/enshroudedserver/enshrouded_server.json`.
**Stop the server before editing it** — a running server rewrites the file on
shutdown and discards manual edits.

## Restore

```sh
systemctl stop enshrouded
tar -xzf /var/backups/enshrouded/savegame-<stamp>/savegame.tar.gz \
  -C /home/enshrouded/enshroudedserver
cp /var/backups/enshrouded/savegame-<stamp>/enshrouded_server.json \
  /home/enshrouded/enshroudedserver/
systemctl start enshrouded
```

## Known behavior — high CPU/load is expected

The Windows server under Wine is CPU-hungry even when idle or with one player:
`enshrouded_server.exe` holds ~1-2 cores and `wineserver64` another ~0.3,
continuously, and the server log emits `[server] Bad Performance ~20,000 us`
lines every few seconds. This is a known property of the Wine compatibility
layer, not a fault of this host or role — Wine reports a high "hosting load"
where Proton does not, at the cost of lower network latency, and there is no
fix short of the native Linux dedicated server (still unreleased). See
`mornedhels/enshrouded-server` issue #202 and the feature request for a native
build.

The LXC is deliberately **not** CPU-capped (`cpulimit` unset): the host has
headroom (16 threads, ~50% idle) and the game is the point of running it. If
the co-located Minecraft server or the KVM workloads ever contend visibly,
cap `ct-dmz-games-01` in `terraform/stacks/proxmox/lxc.tf` and accept the drop
in game quality. Host CPU pressure `full` staying at 0 is the signal that no
cap is currently needed.

## Reachability

- **LAN** — UDP `15636,15637` allowed from `10.0.0.0/8` and `192.168.178.0/24` by
  MikroTik rules in `terraform/stacks/network/firewall_extra.tf`.
- **Remote** — a playit.gg tunnel (same agent as Minecraft). Create the UDP tunnel
  for `15637` in the playit dashboard and point it at `10.0.30.3:15637`. The agent
  is installed by the base image, not this role.

## Dependencies

- Docker is **not** used; the base image's `nesting`/`docker` stack is unrelated.
- Wine needs i386 multiarch enabled (the role does this).
- Backup retention assumes the PBS→R2 job covers the LXC rootfs.
