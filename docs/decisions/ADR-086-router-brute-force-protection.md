# ADR-086: Router brute-force protection matches what is actually exposed

**Date:** 2026-11-25
**Status:** Accepted, applied

## Context

The input chain carried a brute-force pair from the original router setup: `IN-00a` added
any source with more than three concurrent connections to TCP 22/8291 to
`brute_force_blocked` for a day, and `IN-00b` dropped that list. Both sat below
`IN-02` (accept `Mgmt_Devices`) and directly above the default drop. A source in
`Mgmt_Devices` was accepted before reaching them; every other source was dropped by the
default rule anyway. Both rules showed zero packets after 12 weeks of uptime. They
protected nothing, and the comment ("3 attempts/IP") described a rate limit the rule did
not implement.

What is actually reachable from outside the management VLANs:

| Path | Reachable from | Protection before this change |
|---|---|---|
| TCP 443 -> ct-dmz-proxy-01 (headscale) | Internet, via the FritzBox forward | CrowdSec on the nginx proxy |
| UDP 41641 -> rpi-srv-02 (tailscaled) | Internet | WireGuard: a peer without a known key gets no answer |
| SSH, WinBox, API, REST on the router | `Mgmt_Devices` (VLAN 10, VLAN 100) and, for 443/8728/8729, the SRV VLAN | default drop for everything else |
| MAC-Telnet, MAC-WinBox | every interface, including ether1 | admin password only |

The last row is the real gap. Layer-2 management frames do not pass the IP firewall, and
ether1 shares a broadcast domain with the FritzBox LAN (phones, TVs, guests). Any device
there could reach the router's login with MAC-WinBox.

## Decision

- **Drop the dead pair** (`IN-00a`, `IN-00b`). The default drop already covers the case
  they claimed to cover.
- **Limit MAC-Telnet and MAC-WinBox** to an interface list `mac-access`: `vlan100-admin`,
  `vlan10-mgmt`, `bridge1` (untagged) and `ether4`, the non-bridged port that keeps its
  factory address. ether1 is no longer in it.
- **Connection-flood guard on WAN TCP 443**: a WAN source opening a new connection while
  it already holds more than 32 goes onto `wan_conn_flood` for an hour, and that list is
  dropped before the headscale accept. FritzBox-LAN sources are exempt, because hairpinned
  traffic from the LAN can share one source address. A headscale client holds one or two
  connections, so 32 leaves a wide margin. Login brute force against the web UI stays
  CrowdSec's job; the router cannot see inside TLS.
- **No rule for UDP 41641.** WireGuard does not answer unauthenticated handshakes, so
  there is nothing to brute-force, and a rate limit would only risk dropping real peers.

## Consequences

- No change to IP access from the admin VLAN or to the Terraform runner's REST path, so
  the usual management route is also the rollback route for this change.
- MAC access from the FritzBox LAN stops working. Recovery when IP access is broken: a
  cable on ether4 or a machine in the admin VLAN. `power_disable_unused_ports` lists ether4;
  if that scheduler ever takes effect, the admin VLAN is the remaining MAC path.
- A misbehaving client with more than 32 parallel connections from one public address is
  locked out of headscale for an hour. The list is visible in
  `/ip firewall address-list` (`wan_conn_flood`).

## Alternatives considered

- **Staged SSH/WinBox rate lists in front of `IN-02`.** Would only ever act on
  `Mgmt_Devices`, which can already reach the hypervisor; it adds lockout risk for the
  admin workstation without covering any untrusted source.
- **Router-side CrowdSec bouncer (address list pushed over the API).** Duplicates the
  bouncer that already runs on the proxy and adds a writer with API credentials.
