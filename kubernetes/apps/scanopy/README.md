# Scanopy

Self-hosted network topology mapping ([scanopy.net](https://scanopy.net), AGPL-3.0
Community Edition). A central server plus one daemon per covered VLAN builds an
interactive, self-updating map of hosts and services — replaces manually redrawing the
architecture diagram every time something changes.

Covers VLAN10 (MGMT), VLAN20 (SRV), VLAN30 (DMZ). VLAN40 (IoT) and VLAN100 (Admin) are
deliberately excluded — see `docs/decisions/ADR-035-scanopy-topology-mapping.md` for why.

## Architecture

- **Server + Postgres** run here (`apps`/`database` namespaces), reachable in-cluster on
  `scanopy-server.apps.svc.cluster.local:60072`.
- **SRV daemon** (`scanopy-daemon-srv`, this file): `hostNetwork: true` pod, same
  cluster. Bypasses NetworkPolicy entirely — see the manifest's own comment before
  changing its egress assumptions.
- **MGMT daemon**: `ct-mgmt-scanopy-01` LXC (`terraform/stacks/proxmox/lxc.tf`),
  `ansible/roles/scanopy_daemon/`.
- **DMZ daemon**: docker-compose sidecar on the existing `ct-dmz-proxy-01`
  (`ansible/roles/nginx_proxy_manager`, gated by `npm_enable_scanopy_daemon`) — no new
  box, same pattern as that host's `node_exporter`/`promtail`/`crowdsec` sidecars.

All three daemons use DaemonPoll (daemon connects out to the server; no inbound path to
any daemon exists). The MGMT and DMZ daemons reach the server through
`scanopy-server-daemon-lb`, a `LoadBalancer` Service scoped via `loadBalancerSourceRanges`
to exactly those two hosts, matched by narrow forward rules in
`terraform/stacks/network/firewall_deterministic.tf` (same shape as headscale's DMZ
path). No WAN/dstnat involvement at all — this stays fully internal.

## First-time setup (manual, can't be templated ahead of time)

1. Apply `kubernetes/system/postgres/user-scanopy.yml.example` (fill in the password) and
   `scanopy-server-secret.yml.example` (same password, in the DSN) as real Secrets —
   `kubectl apply -f <edited copy>`, don't commit the filled-in version.
2. Apply `cluster-scanopy.yml`, `scanopy.yml`, wait for the server pod to be Ready.
3. Log into the Scanopy UI at `scanopy-server.apps.svc.cluster.local:60072` (port-forward
   to reach it), create 3 Networks (one per VLAN: 10.0.10.0/24, 10.0.20.0/24,
   10.0.30.0/24), generate a daemon API key per Network.
4. Fill in `scanopy-daemon-srv-secret.yml.example` with the SRV key, apply it.
5. Run the `scanopy_daemon` Ansible role against `ct-mgmt-scanopy-01` and (with
   `npm_enable_scanopy_daemon: true`) `ct-dmz-proxy-01`, each with its own API key/network
   ID in `ansible/group_vars/`.

## Known gotchas

- No passive/ARP-only scan mode exists in Scanopy itself — a daemon full-port-scans
  whatever subnet it's placed on. Safety here comes from daemon placement and firewall
  scope, not a scan-intensity setting.
- The SRV daemon's `hostNetwork: true` means it is NOT covered by
  `kubernetes/apps/network-policies-egress.yml` — don't assume adding a rule there
  changes what it can reach.
- If Community Edition self-hosted turns out to cap networks/hosts (not clearly
  documented — see the ADR), the MGMT+DMZ daemons are the ones to drop first; they're the
  smaller subnets.
