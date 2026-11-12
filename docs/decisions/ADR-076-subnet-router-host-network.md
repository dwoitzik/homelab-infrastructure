# ADR-076: The tailnet subnet router runs on the host network with a fixed port

**Date:** 2026-11-12
**Status:** Superseded the same day. The host-network subnet router was reverted (#1111); direct connections go to rpi-srv-02 instead, see "Outcome" below.

## Context

Remote tailnet clients (the Pixel on mobile data) reached `homelab-router-1`, the
in-cluster subnet router and exit node (`kubernetes/apps/headscale/subnet-router.yml`),
only through Tailscale's DERP relays. Every byte of exit-node and LAN traffic took a
detour through Frankfurt or Amsterdam, which matches the "Headscale works badly"
complaint better than anything on the Headscale side: Headscale's logs are clean and
its route table is correct.

`tailscale netcheck` inside the subnet-router pod:

```text
* IPv4: yes, 178.202.47.0:41720
* MappingVariesByDestIP: true
* PortMapping:
```

The same command on `rpi-srv-02` (Tailscale on the host, same LAN, same MikroTik and
FritzBox in front of it):

```text
* IPv4: yes, 178.202.47.0:48845
* MappingVariesByDestIP: false
```

So the double NAT through MikroTik and FritzBox is endpoint-independent. The
destination-dependent mapping comes from inside the cluster: flannel masquerades pod
egress with `MASQUERADE --random-fully` (`FLANNEL-POSTRTG` on every k3s node), which
picks a new source port per destination. To Tailscale that is a "hard" NAT. Two hard
NATs can never hole-punch, and most mobile carriers are hard NATs too, so the subnet
router fell back to DERP for every off-LAN peer. On the LAN the pod still reached
both Raspberry Pis directly (`tailscale ping` via `10.0.20.2:41641`/`10.0.20.3:41641`),
because no NAT is involved there.

## Decision

Run the `tailscale-subnet-router` pod with `hostNetwork: true`, a fixed WireGuard port
(`TS_TAILSCALED_EXTRA_ARGS=--port=41641`) and Tailscale's nftables firewall mode.

- Host network takes flannel's masquerade out of the path; the node's own path out
  is the same as `rpi-srv-02`'s, which netcheck shows as endpoint-independent.
- The fixed port gives a stable endpoint and a target for an optional WAN port
  forward later. The pod is already pinned to `vm-srv-k3s-11` by its `local-path`
  PVC, so a forward would have a fixed LAN target (10.0.20.11).
- `TS_DEBUG_FIREWALL_MODE=nftables`: the node runs k3s's iptables-nft; Tailscale's
  auto-detection in the pod picked legacy iptables, which in the host netns would sit
  beside k3s's rules in a second backend.

Options not taken:

- **hostPort or a UDP Service** for 41641: the inbound side would work, but outbound
  packets from the pod are still masqueraded by flannel with a random port, so the
  mapping stays hard.
- **Run Tailscale on the k3s node itself (Ansible)**: same network result, but it
  moves the subnet router out of GitOps and away from the auth-key Secret it already
  uses.
- **Static endpoint (`TS_DEBUG_PRETENDPOINT`) plus port forward on the pod network**:
  needs a static WAN address (the WAN address is dynamic, ADR-059) and still leaves the
  outbound mapping hard.

## Consequences

- The three `tailscale-subnet-router` egress NetworkPolicies in
  `kubernetes/apps/network-policies-egress.yml` no longer apply (NetworkPolicy does not
  cover host-network pods). They are kept, with a comment, so a revert works.
- The pod's `postStart` sysctl `net.ipv6.conf.all.forwarding=1` is now node-wide on
  `vm-srv-k3s-11`. The k3s cluster is IPv4-only, so nothing else on the node uses IPv6
  routing.
- Tailscale's nftables tables (`ts-*`) and route table 52 live in the node's netns. The
  subnet router does not accept routes (`RouteAll: false`), so table 52 only carries
  tailnet addresses (100.64.0.0/10, fd7a:115c:a1e0::/48).
- Off-LAN peers behind a hard NAT (some mobile carriers) still need the other side to
  be reachable without a mapping. That takes a UDP 41641 forward on both the FritzBox
  (manual, outside Terraform) and the MikroTik (`dstnat_tailscale_wireguard` in
  `terraform/stacks/network/nat_portforward.tf`). The host network alone fixes the
  case where the remote peer has an endpoint-independent NAT.

## Rollback

Revert the PR. ArgoCD puts the pod back on the pod network; the Deployment uses the
`Recreate` strategy, so there is never a second tailscaled on port 41641. `rpi-srv-02`
is approved for the same three routes and keeps serving them during the restart.

## Outcome

The host-network deployment (#1095) broke pod networking on vm-srv-k3s-11: from
18:12 UTC, pods on the other nodes could not reach any pod on that node, so
Traefik answered 502 for Immich and Authelia among others. It was reverted in
PR #1111 within the hour and the photos/auth paths returned to 200. tailscaled in
the host network namespace of a k3s node competes with kube-router and flannel
for netfilter state and fwmark bits; validating only the tailnet side missed it.

rpi-srv-02 already runs tailscaled on its host, advertises the same routes
(`10.0.20.0/24`, exit node) and reports `MappingVariesByDestIP: false`, so it
gets direct connections without touching the cluster. The WAN port forward
(UDP 41641) now targets rpi-srv-02, and it serves as primary for the LAN route;
the in-cluster router stays as the fallback.

Lesson: a change to a k3s node's host network needs a cross-node pod
reachability check (Traefik to a pod on that node), not only checks of the
component being changed.
