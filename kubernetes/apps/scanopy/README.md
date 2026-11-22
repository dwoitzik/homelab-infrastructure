# Scanopy

Self-hosted network topology mapping ([scanopy.net](https://scanopy.net), AGPL-3.0
Community Edition). A central server plus one daemon per covered VLAN builds an
interactive, self-updating map of hosts and services — replaces manually redrawing the
architecture diagram every time something changes.

Covers VLAN10 (MGMT), VLAN20 (SRV), VLAN30 (DMZ). VLAN40 (IoT) and VLAN100 (Admin) are
deliberately excluded — see `docs/decisions/ADR-035-scanopy-topology-mapping.md` for why.

## Architecture

- **Server + Postgres** run here (`apps`/`database` namespaces). Browser access is
  `https://scanopy.woitzik.dev` (LAN/Tailscale only, Authelia-gated, via the
  `*.woitzik.dev` AdGuard wildcard -> Traefik -> `kubernetes/system/apps-ingressroute.yml`'s
  `scanopy-final` route -- same pattern as every other internal-only tool, never the
  Cloudflare Tunnel). In-cluster consumers (the SRV daemon) use
  `scanopy-server.apps.svc.cluster.local:60072` directly.
- **SRV daemon** (`scanopy-daemon-srv`, this file): `hostNetwork: true` pod in the
  `host-agents` namespace (cannot pass Pod Security baseline), same cluster. Its
  `scanopy-daemon-srv` Secret is created by hand in `host-agents` (see the `.example`). Bypasses NetworkPolicy entirely — see the manifest's own comment before
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
3. Log into the Scanopy UI at `https://scanopy.woitzik.dev` (Authelia first, then the
   Scanopy account), create 3 Networks (one per VLAN: 10.0.10.0/24, 10.0.20.0/24,
   10.0.30.0/24), generate a daemon API key per Network.
4. Fill in `scanopy-daemon-srv-secret.yml.example` with the SRV key, apply it.
5. Run the `scanopy_daemon` Ansible role against `ct-mgmt-scanopy-01` and (with
   `npm_enable_scanopy_daemon: true`) `ct-dmz-proxy-01`, each with its own API key/network
   ID in `ansible/group_vars/`.

## Known gotchas

- No passive/ARP-only scan mode exists in Scanopy itself — a daemon port-scans every
  host it finds on its subnets. Scan intensity is a per-discovery setting stored on the
  server (`discovery.discovery_type -> scan_settings`: `scan_rate_pps`, default 500;
  `port_scan_batch_size`, default 200; `full_scan_interval`, default every 3rd run is a
  full 65k-port scan). Set it in the UI under the discovery's settings. Daemon env vars
  like `SCANOPY_SCAN_RATE_PPS` are deprecated and ignored (the daemon logs
  `Deprecated config: ... scan_rate_pps`).
- The rate applies per scanned host, and all hosts are scanned in parallel. Probes that a
  firewall or NetworkPolicy drops stay in the daemon node's conntrack table as
  `UNREPLIED SYN_SENT` for 120 s; at the 500 pps default a full scan filled the SRV
  node's whole table. The SRV discovery runs at `scan_rate_pps: 50`, and
  `SCANOPY_INTERFACES=eth0` keeps the daemon off the node's pod CIDR (`cni0`), where
  every probe is dropped. `HostConntrackTableFull` alerts at 90 %.
- A daemon's identity lives in its config dir (`/root/.config/daemon/config.json`, a
  PVC for the SRV daemon, a bind mount for the compose daemons). Lose it and the daemon
  registers again as a new daemon with a new scheduled discovery at default scan
  settings, so the settings above have to be set again and the old daemon deleted.
- In v0.16.2 the server's cron job keeps a copy of the discovery from when it was
  scheduled (server start, or a schedule or enable change) and runs and writes back that
  copy. A scan setting changed in the UI or the database is used, and kept, only after
  `kubectl -n apps rollout restart deploy/scanopy-server` or toggling the schedule off
  and on in the UI.
- The SRV daemon's `hostNetwork: true` means it is NOT covered by
  `kubernetes/apps/network-policies-egress.yml` — don't assume adding a rule there
  changes what it can reach.
- If Community Edition self-hosted turns out to cap networks/hosts (not clearly
  documented — see the ADR), the MGMT+DMZ daemons are the ones to drop first; they're the
  smaller subnets.
