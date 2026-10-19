# ADR-065: Enshrouded dedicated server on the DMZ game LXC

## Status

Accepted and applied, 2026-10-19.

## Context

The operator runs a Minecraft server on `ct-dmz-games-01` (LXC 302, VLAN 30) and
asked to add an Enshrouded dedicated server on the same box. Enshrouded's server is
a free SteamCMD app (`2278520`), but it is Windows-only: SteamCMD on Linux silently
downloads ~100 MB of shared libraries, reports success, and leaves no executable
unless the Windows depot is requested explicitly with
`+@sSteamCmdForcePlatformType windows`. The real payload (~8.3 GB, 32 `.dat`
containers plus `enshrouded_server.exe`) runs under Wine.

Two constraints shaped the design:

- **The host is memory-tight.** `pve-mgmt-01` has 62 GB physical RAM, and before
  this change the single largest unused reservation was `ct-srv-ai-01` (24 GB
  dedicated) against ~36 MB of live usage — Ollama holds no model in RAM when
  idle. The games LXC had 12 GB.
- **The DMZ is walled off.** MikroTik's `fwd_99_drop_all` drops inter-VLAN forward
  traffic. Minecraft reaches players through explicit TCP allow-rules and, off-LAN,
  through a playit.gg tunnel. Enshrouded needed the same "reachable but not opened
  to the internet" shape, as UDP.

## Decision

**Host it natively under Wine, managed as an Ansible role** (`roles/enshrouded`),
not via a third-party Docker image. The role installs Wine + the Windows SteamCMD
depot, runs the server under `xvfb-run` (the binary expects a display even
headless), manages `enshrouded_server.json`, and installs a `systemd` unit with
`Restart=on-failure`. A daily cron backs up `savegame/` and restarts the server.

**Reachability, in two lanes:**

- **LAN** — two MikroTik forward rules (`fwd_internal_to_dmz_enshrouded`,
  `fwd_heimnetz_to_dmz_enshrouded`) accepting UDP `15636,15637` from `10.0.0.0/8`
  and the FritzBox LAN respectively, placed before the final drop. Remote access
  uses the existing playit agent, same as Minecraft — the game port is never
  opened on the WAN.
- The live rules were added through the router REST API the same day to unblock
  play before the normal Terraform apply cycle, and adopted into state with
  `import` blocks (`terraform/stacks/network/imports.tf`, ids `*C3`/`*C4`) so the
  next apply reconciles rather than conflicting.

**Resource rebalance to make room** (`terraform/stacks/proxmox/lxc.tf`):

- `ct-srv-ai-01`: 4 cores/24 GB → 2 cores/4 GB. It is barely used; 4 GB still fits
  a small model (`qwen2.5:7b`, ~5 GB, swapping).
- `ct-dmz-games-01`: 4 cores/12 GB → 6 cores/16 GB, rootfs 50 GB → 100 GB (the
  8.3 GB install needs room for a same-size steamcmd staging copy on update).

The port agreement is worth recording: the current server version writes only
`queryPort` (15637) — it drops the `gamePort` field older guides cite — and binds a
single UDP port. Both 15636 and 15637 are allowed anyway, since which one a given
client build uses has varied.

## Consequences

- The host's LXC `dedicated` sum drops from ~67 GB to ~45.5 GB; the two-tier
  overcommit gate (`scripts/check-host-memory-overcommit.py`) stays green.
- Enshrouded and Minecraft now share the games LXC. 6 cores / 16 GB covers both
  at the observed loads, but a cold Wine start plus a busy world can transiently
  squeeze RAM; the LXC has 2 GB swap as a buffer.
- The Ansible Minecraft role had drifted from reality (it still declared
  `mc-server-2`/`data-3` while the live container was `mc-server-4`/`data-4`); the
  same PR aligns it, since running the play is what surfaced the gap.
- Remote play still depends on a playit.gg tunnel being created for the Enshrouded
  UDP port in the playit dashboard; the agent is installed but tunnel creation is a
  dashboard-side action outside this repository.

## Alternatives considered

- **`mornedhels/enshrouded-server` Docker image** — bundles SteamCMD, auto-update
  and daily restart. Rejected: a bespoke Wine install is more transparent and
  matches the repo's preference for first-party systemd/Ansible over an opaque
  third-party image for a stateful game server.
- **Shrinking every LXC to fit** — unnecessary; one idle 24 GB reservation covered
  the entire need.
