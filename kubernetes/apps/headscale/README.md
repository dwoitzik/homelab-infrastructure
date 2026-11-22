# Headscale

Self-hosted control server for the homelab's Tailscale mesh (this recovery agent's own
`claude-agent` identity connects through it, as does the LAN subnet router).

## Storage

Single PVC (`local-path`): `db.sqlite` (registered nodes/users/API keys/pre-auth keys/
policies) and `noise_private.key` (the server's own mesh identity — losing this means
every existing node has to re-register, not just a data inconvenience).

## How to restore

Copy `db.sqlite` + `noise_private.key` onto the PVC, restart. `sqlite3 db.sqlite
"PRAGMA integrity_check;"` before trusting it. Verified 2026-08-13: schema intact,
`nodes`/`users`/`api_keys`/`pre_auth_keys`/`policies` tables present.

## Known gotchas

- **Pre-auth keys expire.** The one this recovery relied on had genuinely expired by the
  time of the rebuild (time passage, not a restore bug) — generate a fresh one with
  `headscale preauthkeys create --user 1 --reusable --expiration 87600h` if the subnet
  router or a new node can't join. If you regenerate one, either update
  `secret/headscale`'s `subnet-router-authkey` in Vault and re-apply
  `external-secret.yml`, or delete the ExternalSecret entirely if you're wiring the new
  key in by hand — otherwise ExternalSecrets' `creationPolicy: Merge` will keep syncing
  the stale value back over your live fix.
- The Traefik IngressRoute for `auth.woitzik.dev` (OIDC discovery) is a *separate*
  resource (`apps-ingressroute.yml`'s `auth-final` entry) from Headscale's own manifests
  here — a missing route there looks exactly like an OIDC config problem but isn't one.
- **OIDC login is LAN/tailnet-only.** `auth.woitzik.dev` has no public DNS (ADR-033), so
  registering a new device or re-logging a logged-out one fails on mobile data at the
  browser step. Do it from home Wi-Fi, or use a pre-auth key.
- **Tailnet clients must get the public control address.** AdGuard answers
  `headscale.woitzik.dev` with the internal Traefik IP, but tailscaled dials control
  outside the tunnel. The `public-ip-record` sidecar writes the public address to
  `extra_records_path`, which MagicDNS serves to tailnet clients;
  `tailnet-route-drift-check` alerts if that answer is ever private or unreachable.
