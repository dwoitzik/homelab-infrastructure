# Rybbit

Self-hosted, privacy-friendly web analytics for woitzik.dev ([rybbit-io/rybbit](https://github.com/rybbit-io/rybbit)).
ClickHouse + Postgres + Redis + backend + client, all Docker Compose on a
dedicated LXC (`ct-srv-rybbit-01`, VLAN20) -- ClickHouse's own memory/CPU
footprint is enough reason not to share a box.

## Architecture

Caddy fronts backend+client behind one port (`/api/*` -> backend:3001,
everything else -> client:3002), listening on plain `:80` only --
`auto_https off`, no ACME. This box has no inbound WAN exposure at all;
Cloudflare Tunnel is the only path in (same pattern as photos.woitzik.dev),
and Cloudflare's own edge terminates public TLS for real visitors. Caddy's
automatic HTTPS would just fail here anyway (no way for Let's Encrypt to
reach this box from the internet).

## First-time setup

Registration starts open (`rybbit_disable_signup: false` in
`group_vars/rybbit_nodes.yml`) so the first real admin account can be
created through the UI. **Immediately after that first signup**, flip
`rybbit_disable_signup: true` and re-run the play -- otherwise anyone who
finds analytics.woitzik.dev can self-register.

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
