# ADR-002: Keepalived for edge node high availability

**Date:**
**Status:** Accepted

## Context

DNS and reverse proxy services run on two Raspberry Pi 4B nodes. These are critical path services — if either node goes down and clients lose their DNS resolver or ingress proxy, the entire homelab becomes unreachable.

Options considered:

- Single node (no HA, accept the downtime risk)
- DNS round-robin across both node IPs
- Keepalived with a shared Virtual IP (VIP)

## Decision

Deploy Keepalived in Active/Passive mode across both Raspberry Pi nodes, exposing a single Virtual IP (VIP) as the client-facing address for DNS and NPM traffic.

## Reasons

**Transparent failover:** Clients point to the VIP. If the primary node fails, Keepalived promotes the replica within seconds — no client reconfiguration, no DNS TTL wait.

**Simpler than DNS round-robin:** Round-robin DNS doesn't detect node health. Clients can continue sending traffic to a dead node until TTL expires. Keepalived performs active health checking via VRRP.

**State synchronisation:** `adguardhome-sync` replicates filter lists and configuration from primary to replica continuously, so the replica is always ready to serve without manual intervention.

**Low resource overhead:** Keepalived runs as a lightweight systemd service with negligible CPU/memory impact on the Pi.

## Trade-offs

- VRRP uses multicast, which requires the MikroTik switch to permit multicast between the two Pi nodes on the same VLAN
- Active/Passive wastes one Pi's capacity (the replica is idle during normal operation)
- Failover is not instantaneous — VRRP dead interval is ~3 seconds by default

## Consequences

Both Pis are provisioned identically via Ansible. The Keepalived config is templated with `priority` as the only differentiator between primary and replica. The VIP is statically assigned and reserved in the MikroTik DHCP server to prevent conflicts.
