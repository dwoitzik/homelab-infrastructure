# ADR-069: Enshrouded 1.0 dropped the Linux depot — Windows depot, Steamworks client path, hourly buildid-checked updates

## Status

Accepted and applied, 2026-10-21.

## Context

Enshrouded 1.0 shipped on 2026-10-15. The client refused to talk to the server
running the pre-1.0 build, so the server had to be updated. The update turned
into an outage, and the cause was not the usual "old build" story.

Steam's depot configuration for app `2278520` changed on 2026-10-21. The Steam
content log recorded it verbatim:

```text
AppID 2278520 config changed : added depots 1006
AppID 2278520 config changed : removed depots 1004,2278521
```

Before that change the app mounted two depots: `1004` (Windows redist) and
`2278521` (the game content). After it, a Linux client mounts exactly one:
`1006` — the 111 MB Linux Steamworks redistributable. The 8.16 GB content depot
still exists on Steam and is still listed for the app, but it is now Windows
only; there is no Linux content depot at all. SteamDB confirms the app's
supported system is Windows and the content depot is 8.16 GiB with a Windows
manifest.

The visible effect of a plain `steamcmd +app_update 2278520 validate` was a
success message. The commit log tells what actually happened:

```text
AppID 2278520 starting commit from ".../steamapps/downloading/2278520" to
"/home/enshrouded/enshroudedserver" : 4 updated, 0 moved, 24 deleted files
```

Four runtime files were updated and 24 game files deleted. The server binary was
gone, the unit failed with `wine: failed to open ".../enshrouded_server.exe":
c0000135`, and the systemd unit crash-looped with `Restart=on-failure`.

Two further facts made this hard to see:

- The **savegame was never touched**. `savegame/world0.ksd` kept its content and
  `enshrouded_server.json` its password throughout; only the executable and the
  32 `.dat` containers were missing. The loss was entirely re-downloadable.
- SteamCMD's three-argument depot form (`+app_update <appid> <depot> <manifest>`)
  was **silently ignored** by the current client build, so explicitly asking for
  the content depot fetched zero bytes and still reported success.

## Decision

**Keep the native Wine deployment, and make the content fetch explicit.**

1. **Always request the Windows depot** with `+@sSteamCmdForcePlatformType
   windows` before `+app_update`. This is the upstream-documented approach
   (`mornedhels/enshrouded-server`) and the only variant that mounts the
   content depot from a Linux host. It is what the role already did for the
   initial install — the failure was that the scheduled update path ran without
   it in the live system.
2. **Point Steamworks at a client install directory.** The 1.0 binary initialises
   Steamworks before it does anything else, and aborts with `Could not determine
   Steam client install directory` when it cannot resolve one. The unit exports
   `STEAM_COMPAT_CLIENT_INSTALL_PATH=~/.steam/steam`, and the role links
   `steamclient.so` into `~/.steam/sdk32`, `~/.steam/sdk64` and `~/.steam/steam`.
   This mirrors what the upstream Proton image does with its own SDK links.
3. **Check the buildid hourly instead of updating on a fixed schedule.** The
   update script compares the buildid in `steamapps/appmanifest_2278520.acf`
   against `/var/lib/enshrouded/current_buildid`. Only a changed build triggers
   a SteamCMD run and a restart. An unchanged build is a no-op, so the server
   keeps running with connected players instead of being bounced on a timer.
   The previous weekly cron was replaced by `enshrouded-autoupdate.timer`
   (hourly, with a randomised delay).

The update script fails loudly rather than silently: if the appmanifest is gone
after a SteamCMD run, it exits non-zero instead of restarting a server whose
binary may no longer exist.

## Consequences

- The server needs ~8.2 GB on disk for content plus a same-size staging copy
  during an update. The role asserts 25 GB free on `/` before installing, and
  the update window is the only time the disk footprint doubles.
- A real update drops connected players. The buildid check minimises how often
  that happens, but an announced maintenance window is still the honest way to
  handle an actual version bump.
- The hourly check is cheap when nothing changed: it reads one appmanifest and
  exits. The SteamCMD run only happens on a buildid change.
- `DepotDownloader` was evaluated as a fallback for fetching the content depot
  directly and rejected: the old Linux manifest is no longer served to anonymous
  accounts (HTTP 401), and the current manifest fetch is a workaround for a
  problem `+@sSteamCmdForcePlatformType windows` solves properly.
- The upstream project also publishes a Proton-based image. Proton was not
  adopted: the native Wine path works with the 1.0 build once Steamworks finds
  its client directory, and switching runtime engines would invalidate the
  `WINEFSYNC`/`WINEESYNC` tuning that fixed the tick stalls documented in
  ADR-065.

## Alternatives considered

- **Proton (GE-Proton 11-9) instead of native Wine** — upstream's recommended
  path for 1.0, and it carries the newer Steamworks libraries that the
  "Version Mismatch / No SteamUtils011" reports refer to. Rejected for now: the
  native path reaches `HostOnline` with the same content, and a runtime change
  is a bigger blast radius than the missing client directory. Revisit if the
  native build starts rejecting the client version.
- **Roll back to the pre-1.0 build** — the old Linux depot manifest is not
  served to anonymous accounts anymore, and a pre-1.0 server cannot host 1.0
  clients. It would also have left players unable to connect, which is the
  problem the update was meant to solve.
- **Keep the weekly cron and only add the buildid check** — would have kept the
  weekly gap in which a client update arrives before the server does. The check
  is only worth something if it runs more often than the client update window.
