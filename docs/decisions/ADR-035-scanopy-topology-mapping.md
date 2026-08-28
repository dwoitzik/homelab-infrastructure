# ADR-035: Scanopy for Network Topology Mapping

**Date:** 2026-08-28
**Status:** Accepted

## Context

Architecture documentation for this repo is manually maintained and drifts from
reality over time — the recurring pattern this repo already fights (declared-vs-live
drift, see ADR-027) applies just as much to network topology diagrams as it does to
Terraform state. [Scanopy](https://scanopy.net) (AGPL-3.0, self-hosted) automates
this: per-VLAN daemons perform ARP discovery and TCP service fingerprinting, a
central server builds a self-updating topology map.

The operator wants this, with an explicit preference for erring toward too much
security rather than too little, given the network's segmentation work is otherwise
complete and the DMZ path was just hardened.

## Decision

**Cover VLAN10 (MGMT), VLAN20 (SRV), VLAN30 (DMZ). Explicitly exclude VLAN40 (IoT)
and VLAN100 (Admin).** Both excluded VLANs have zero persistent compute today — IoT
is untrusted consumer devices, Admin is the operator's own workstation — and neither
is worth standing up new, dedicated scanning infrastructure for. A scanner's value is
proportional to how much self-hosted infrastructure a segment actually has; these two
have none.

**DaemonPoll mode everywhere, not ServerPoll.** Scanopy offers two connection modes:
DaemonPoll (daemon connects outbound to the server, no inbound path to the daemon
needed) and ServerPoll (server connects inbound to the daemon on a fixed port).
Upstream's own docs suggest ServerPoll for DMZ deployments specifically, reasoning
that a DMZ host "cannot make outbound connections" — that reasoning doesn't apply
here (this DMZ box already makes narrow, deliberate outbound connections, e.g. to
CrowdSec's CAPI), and DaemonPoll is strictly the safer direction: nothing ever
initiates a connection *into* the DMZ daemon from elsewhere on the network.

**No `privileged: true`, no Docker-socket mount.** Upstream's own `docker-compose.yml`
runs the daemon with full `privileged: true` and a read-only Docker-socket bind mount
(the latter for auto-tagging what's running in Docker on the scanned host). Neither is
required for the actual job (ARP discovery + raw TCP port scanning) — `NET_RAW` +
`NET_ADMIN` capabilities are the real requirement. A read-only Docker-socket mount is
still full Docker API access (the daemon's own file-mount permissions don't gate what
the Docker API itself allows over that socket) — effectively root over whatever host
it's mounted on. Granting that to a network scanner, especially the one sitting next
to the DMZ's CrowdSec/NPM stack, defeats the purpose of running a scanner carefully in
the first place. Trade-off accepted: no automatic container-to-service correlation:
this needs manually confirming what a discovered open port belongs to.

**Narrowest possible firewall rule per daemon, no WAN exposure at all.** The MGMT and
DMZ daemons reach the server through a dedicated `LoadBalancer` Service
(`scanopy-server-daemon-lb`) scoped via `loadBalancerSourceRanges` to exactly those
two hosts' /32 addresses, matched by equally narrow MikroTik forward rules (single
source host, single destination, single port). Unlike headscale's DMZ exposure, this
has zero public/WAN-facing component — it is fully internal by design.

## Alternatives considered

- **ServerPoll for the DMZ daemon** (upstream's suggested default for DMZ) — rejected;
  see Decision above, this is the wrong direction for this network's actual
  constraints.
- **`privileged: true` + Docker-socket mount everywhere** (upstream's demo default) —
  rejected for the reasons above; can be revisited per-host if NET_RAW+NET_ADMIN turns
  out to be genuinely insufficient for scanning to function, but that would be a
  deliberate, reviewed change, not a default.
- **Covering all 5 VLANs** — rejected; see Decision above on VLAN40/100.
- **Remote (Layer-3-only) scanning of VLAN40/100 from a VLAN20 daemon**, instead of
  placing daemons there — considered and rejected too: this would still need a new
  firewall hole from SRV into segments that currently have none at all, for subnets
  with no self-hosted services worth documenting in the first place.

## Consequences

- `hostNetwork: true` on the SRV daemon means it is not covered by
  `kubernetes/apps/network-policies-egress.yml` — its egress is governed by the node's
  OS and the MikroTik firewall only. Anyone changing that NetworkPolicy file should
  not assume it touches this daemon.
- A new, minimal, single-purpose LXC (`ct-mgmt-scanopy-01`) exists on VLAN10 purely to
  host the MGMT daemon — the one segment with no existing host to piggyback on.
- No automatic Docker-container-to-open-port correlation (see the privileged/socket
  trade-off above) — open ports show up, but connecting them to "which container" is
  manual.
