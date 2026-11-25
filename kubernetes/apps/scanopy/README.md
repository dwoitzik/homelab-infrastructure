# Scanopy

Self-hosted network topology mapping ([scanopy.net](https://scanopy.net), AGPL-3.0
Community Edition). A central server plus one daemon per covered VLAN builds an
interactive, self-updating map of hosts and services — replaces manually redrawing the
architecture diagram every time something changes.

Covers VLAN20 (SRV) only, through one in-cluster daemon. The planned MGMT (VLAN10) and
DMZ (VLAN30) daemons were never finished and were retired on 2026-11-25: those VLANs hold
a handful of hosts that are all defined in IaC, and each extra scanner costs conntrack
load and a firewall opening. VLAN40 (IoT) and VLAN100 (Admin) were excluded from the
start. See `docs/decisions/ADR-035-scanopy-topology-mapping.md`.

## Architecture

- **Server + Postgres** run here (`apps`/`database` namespaces). Browser access is
  `https://scanopy.woitzik.dev` (LAN/Tailscale only, Authelia-gated, via the
  `*.woitzik.dev` AdGuard wildcard -> Traefik -> `kubernetes/system/apps-ingressroute.yml`'s
  `scanopy-final` route -- same pattern as every other internal-only tool, never the
  Cloudflare Tunnel). The SRV daemon uses the ClusterIP Service
  `scanopy-server.apps.svc.cluster.local:60072`; the server has no LoadBalancer and no
  path from other VLANs.
- **SRV daemon** (`scanopy-daemon-srv`, this file): `hostNetwork: true` pod in the
  `host-agents` namespace (cannot pass Pod Security baseline), same cluster. Its
  `scanopy-daemon-srv` Secret is created by hand in `host-agents` (see the `.example`). Bypasses NetworkPolicy entirely — see the manifest's own comment before
  changing its egress assumptions.

The daemon uses DaemonPoll (it connects out to the server; no inbound path to it exists).

## First-time setup (manual, can't be templated ahead of time)

1. Apply `kubernetes/system/postgres/user-scanopy.yml.example` (fill in the password) and
   `scanopy-server-secret.yml.example` (same password, in the DSN) as real Secrets —
   `kubectl apply -f <edited copy>`, don't commit the filled-in version.
2. Apply `cluster-scanopy.yml`, `scanopy.yml`, wait for the server pod to be Ready.
3. Log into the Scanopy UI at `https://scanopy.woitzik.dev` (Authelia first, then the
   Scanopy account), create the Network and generate a daemon API key for it.
4. Fill in `scanopy-daemon-srv-secret.yml.example` with the key and network ID, apply it.

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
  node's whole table. Most SRV hosts drop closed-port probes, so the table holds roughly
  hosts x rate x 120 s x 2: at 50 pps a full scan of 16 hosts passed 75 % of the 131k
  table within two minutes. The SRV discovery runs at `scan_rate_pps: 10`, which held
  20-30 % on the same scan (a full 65k-port scan then takes about two hours). Lower it
  further if the host count grows a lot. `SCANOPY_INTERFACES=eth0` keeps the daemon off
  the node's pod CIDR (`cni0`), where every probe is dropped. `HostConntrackTableFull`
  alerts at 90 %.
- A daemon's identity lives in its config dir (`/root/.config/daemon/config.json`, a
  PVC). Lose it and the daemon
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
