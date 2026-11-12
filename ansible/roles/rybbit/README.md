# Rybbit

Self-hosted, privacy-friendly web analytics for woitzik.dev ([rybbit-io/rybbit](https://github.com/rybbit-io/rybbit)).
ClickHouse + Postgres + Redis + backend + client, all Docker Compose on a
dedicated LXC (`ct-srv-rybbit-01`, 10.0.20.205, VLAN20, host group
`rybbit_nodes`) -- ClickHouse's own memory/CPU footprint is enough reason not
to share a box. The LXC itself is `ct_srv_rybbit_01` in
`terraform/stacks/proxmox/lxc.tf`.

## Architecture

Caddy fronts backend+client behind one port (`/api/*` -> backend:3001,
everything else -> client:3002), listening on plain `:80` only --
`auto_https off`, no ACME. TLS ends at Cloudflare (public) or Traefik (LAN).
Routing, the open tracker endpoints and the Authelia gate on the dashboard are
described in `kubernetes/apps/rybbit/README.md` and ADR-074.

The tracker is embedded in woitzik.dev's `src/layouts/PageLayout.astro`
(`https://analytics.woitzik.dev/api/script.js`, `data-site-id`).

## Deploy

```bash
cd ansible
ansible-playbook site.yml --limit rybbit_nodes --check --diff
ansible-playbook site.yml --limit rybbit_nodes
```

The role writes `/opt/rybbit/{Caddyfile,docker-compose.yml}`, brings the stack
up with `docker compose`, and installs `rybbit-healthcheck.sh` (cron, every 5
minutes).

## Monitoring

- `node-exporter-rybbit` scrape job (10.0.20.205:9100, from the
  `monitoring_agent` role) and `blackbox-rybbit-public`, which probes
  `https://analytics.woitzik.dev/api/health` through public DNS and the tunnel.
- `rybbit-healthcheck.sh` writes `rybbit_container_up{container}` and
  `rybbit_last_event_timestamp_seconds` into node_exporter's textfile directory.
- Alerts: `kubernetes/system/monitoring/rybbit-alerts.yml` (host down, container
  down or unhealthy, no event in 36h, rootfs over 85%) and `ExternalProbeFailed`.
- Container logs go to Loki through promtail (`monitoring_agent` role).

## Data and backups

All state is in Docker named volumes under `/var/lib/docker/volumes/` on the
LXC's rootfs (`local-lvm:vm-205-disk-0`): `rybbit_clickhouse-data` (events),
`rybbit_postgres-data` (users, sites, settings), `rybbit_redis-data` (cache and
queues). The nightly PBS job (`nightly-backup`, `all 1`, snapshot mode) backs up
the whole container, so the volumes are covered. A snapshot-mode backup is
crash-consistent; Postgres (WAL) and ClickHouse (immutable parts) both recover
from that.

ClickHouse has no TTL on `analytics.events`; data grows with traffic and is
small (well under 1 GB). `RybbitDiskFilling` fires before the rootfs fills.

### Restore

- Whole LXC: restore vmid 205 from PBS (see `DISASTER-RECOVERY.md`, including
  the IP/MAC-conflict note when restoring next to a running original).
- Only Rybbit's data: restore the backup to a scratch vmid, stop the stack on
  the live LXC (`docker compose -f /opt/rybbit/docker-compose.yml down`), copy
  the three volume directories across, `docker compose up -d`.

## First-time setup

Registration starts open (`rybbit_disable_signup: false` in
`group_vars/rybbit_nodes.yml`) so the first real admin account can be
created through the UI. **Immediately after that first signup**, flip
`rybbit_disable_signup: true` and re-run the play -- otherwise anyone who
finds analytics.woitzik.dev can self-register. It is `true` today; check with
`POST /api/auth/sign-up/email`, which must answer
`EMAIL_PASSWORD_SIGN_UP_DISABLED`.

## Known gotchas

- All four secrets (`rybbit_postgres_password`, `rybbit_clickhouse_password`,
  `rybbit_redis_password`, `rybbit_better_auth_secret`) live in
  `ansible/group_vars/all/vault.yml` as `vault_rybbit_*` -- rotate there,
  not in the compose file.
- ClickHouse's resource limits (`max_memory_usage`, `max_threads` in the
  role's `docker-compose.yml.j2`) are sized down from upstream's defaults
  (32 GB / 16 threads) to match this LXC's actual 4 GB / 2 vCPU -- don't
  copy upstream's numbers back in if updating the compose file from a newer
  release.
- Rybbit's login has no second factor. Authelia in front of the dashboard is
  the 2FA; keep the dashboard off the open tracker route.
- Page views from LAN/Tailscale arrive without `Cf-Connecting-Ip`, so they are
  recorded without a country. Exclude the LAN ranges in the site settings if
  own visits should not count.
