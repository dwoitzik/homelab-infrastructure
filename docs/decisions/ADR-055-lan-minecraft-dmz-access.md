# ADR-055: Minecraft reachability for LAN players through the DMZ stream proxy

**Status:** Accepted and applied, 2026-10-15

## Context

Two independent breakages stopped players reaching the Paper server
(`ct-dmz-games-01`, `10.0.30.3`) on 2026-10-15:

1. **The external path (playit.gg) is broken by a playit-side bug.**
   `mc.woitzik.dev` is a Cloudflare CNAME to the playit tunnel
   (`doing-sigma.gl.joinmc.link`). The agent (`playit-agent` 1.0.10) is handed
   an IPv6 relay address by playit's control API
   (`[2602:fbaf:840::1]:5525`) and never falls back to IPv4 when IPv6 is
   unreachable (`AddrNotAvailable`, `SessionNotSetup` reconnect loop) —
   upstream issue [#194]. The homelab has no IPv6 uplink on the DMZ, so the
   agent cannot establish the tunnel. Disabling IPv6 locally does not help:
   the relay address comes from playit's API, not local DNS. The documented
   workaround is an account setting (`playit.gg/account/settings` → allow IPv6
   = IPv4 only), which remains the reliable external path for players outside
   the LAN.

2. **The internal path was never opened.** `mc.woitzik.dev` resolves to
   `10.0.30.3` internally (AdGuard rewrite), and `cobblemon.woitzik.dev` to the
   NPM stream proxy `10.0.30.2`. But the MikroTik forward chain isolates the
   DMZ (`10.0.30.0/24`) with no accept rule from either the internal VLANs or
   the FritzBox LAN (`192.168.178.0/24`) — the only Heimnetz allow was
   `→10.0.20.200:80,443`. So a FritzBox-LAN player (or any internal player not
   on the Admin VLAN) got the connection dropped, whether they typed the proxy
   IP or the game LXC IP. Separately, the `npm` container had never published
   the stream ports at all (see the companion fix), so even a permitted
   connection to `10.0.30.2:25565` would have been refused.

The DMZ is deliberately isolated; every hole into it is explicit. Minecraft is
a player-facing service that legitimately needs two such holes.

## Decision

1. **Publish the NPM stream ports.** `npm_stream_ports` (`25565:25565`,
   `25566:25566`) added to `group_vars/dmz_proxies.yml` and looped into the
   npm compose `ports:`. The stream configs (`1.conf`/`2.conf`) already existed
   and point at `10.0.30.3`; they simply had no host port bound.

2. **Allow the two DMZ Minecraft ports from LAN sources, before the final
   drop.** New forward-chain accepts:
   - `20`: `10.0.0.0/8` → `10.0.30.0/24` tcp `25565,25566`
   - `21`: `192.168.178.0/24` → `10.0.30.0/24` tcp `25565,25566`

   Scoped to exactly two ports and the single service; all other DMZ traffic
   stays dropped.

3. **Masquerade the FritzBox-LAN path.** `srcnat_masquerade_heimnetz_to_dmz`
   mirrors the existing Heimnetz→SRV rule — the FritzBox LAN is a foreign
   subnet to the DMZ and needs its return traffic NATed back through `ether1`.

The player-facing path becomes, for both internal and FritzBox-LAN clients:
`client → 10.0.30.2 (NPM stream proxy, CrowdSec in front) → 10.0.30.3:25565`.
The proxy is the single documented entry point; direct-to-LXC is allowed only
because AdGuard already rewrites `mc.woitzik.dev` to `10.0.30.3` for internal
clients.

## Consequences

- FritzBox-LAN and internal players reach Minecraft without depending on a
  third-party tunnel, which is the change that actually restores their access
  today (playit is broken independently).
- The DMZ gains one scoped service exposure from the LAN. Blast radius is the
  two game ports on two hosts; no other DMZ service becomes reachable.
- The DMZ proxy now sees LAN players as the router IP (masquerade), not their
  real source IP — already true for every other Heimnetz→internal service, and
  LAN players are trusted.
- **The playit path is unchanged and still broken** pending the account-side
  setting. This ADR does not fix it; it removes the dependency for LAN players.
  The setting should still be applied (`Allow IPv6 → Only IPv4`) so the mobile
  editors work over the internet; if playit does not recover, an ADR to drop
  the tunnel in favour of the FritzBox-side forward is the fallback.

[#194]: https://github.com/playit-cloud/playit-agent/issues/194
