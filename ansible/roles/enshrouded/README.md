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
  Since Enshrouded 1.0 (2026-10-15) the game ships **no Linux depot at all** —
  a plain `+app_update` on linux mounts only depot 1006 (the Steamworks
  redistributable) and deletes the game content, leaving no server binary.
- Steam client libraries linked into `~/.steam/sdk32`, `~/.steam/sdk64` and
  `~/.steam/steam`, plus `STEAM_COMPAT_CLIENT_INSTALL_PATH` in the unit.
  Steamworks resolves the client install directory from there; without it the
  1.0 binary aborts with "Could not determine Steam client install directory"
  and never reaches `HostOnline`.
- `/home/enshrouded/enshroudedserver` (install), `enshrouded_server.json`, and a
  `Restart=on-failure` unit running
  `xvfb-run -a wine enshrouded_server.exe`.
- Daily cron: `savegame/` backup (14-day local retention) at 04:30, restart at
  05:00. The whole LXC rootfs is also captured by the nightly PBS job → R2, so the
  local copies are the fast-restore path, not the only backup.
- Hourly timer (`enshrouded-autoupdate.timer`): compares the installed buildid
  against `/var/lib/enshrouded/current_buildid` and only runs SteamCMD and
  restarts the server when the build actually changed. An unchanged build is a
  no-op, so the server is never bounced for nothing.
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

### Updates

The hourly timer runs the update script; `journalctl -t enshrouded-autoupdate`
shows what it decided.

```sh
systemctl list-timers | grep enshrouded     # when the next check runs
systemctl start enshrouded-autoupdate.service   # run a check now
journalctl -t enshrouded-autoupdate -n 20
cat /var/lib/enshrouded/current_buildid       # the buildid the server runs
tail -50 /var/log/enshrouded-steamcmd.log      # the last SteamCMD run
```

A check that finds the same buildid logs `unchanged -- no action` and leaves
the server alone. When the build changed, SteamCMD runs against the Windows
depot, the new buildid is recorded, and the server is restarted — connected
players are dropped at that point, so announce it.

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

## Known behavior — Wine CPU/load

The Windows server under Wine keeps `enshrouded_server.exe` around 1-2 cores and
`wineserver64` another ~0.3, and logs `[server] Bad Performance ~20,000 us` every
few seconds. The residual line is a known property of the Wine layer (upstream
`mornedhels/enshrouded-server` issue #202), not a fault of this host.

What is **not** intrinsic is the fast-sync mode. Without `WINEFSYNC=1` Wine
serialises every thread wait through the single wineserver socket, which stalls
the server tick hard — 130 ms peaks and dropped packets for two players — even
while the host CPU is half idle. The unit sets `WINEFSYNC=1`/`WINEESYNC=1`;
verify with `tr '\0' '\n' < /proc/$(systemctl show -p MainPID --value enshrouded)/environ`.

The LXC is deliberately **not** CPU-capped: the host has headroom and host CPU
pressure `full` sits at 0. Cap `ct-dmz-games-01` in `terraform/stacks/proxmox/lxc.tf`
only if the co-located Minecraft server or the KVM workloads visibly contend.

## Config ownership

`enshrouded_server.json` belongs to the running server: it rewrites the file on
every start/stop and, if the password it expects is missing, generates a random
one into `userGroups[]`. The role therefore **seeds** it only when absent
(`force: false`) and never overwrites it — editing it by hand is safe only while
the server is stopped. The password comes from `vault_enshrouded_password`; if it
is ever blanked, players are locked out until it is set again.

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
