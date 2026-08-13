# Authelia

Forward-auth SSO in front of most internal services via Traefik middleware
(`Remote-User`/`Remote-Email`/`Remote-Name` headers). Backed by CloudNativePG Postgres
(`kubernetes/system/postgres/cluster.yml`) and Redis (session store).

## Storage / secrets

- Postgres: user database, authentication logs, OAuth2/WebAuthn/TOTP state.
- `storage-key`: the actual data-encryption key for secrets Authelia stores encrypted at
  rest (TOTP secrets, WebAuthn credentials). This is the one value that must survive a
  restore intact — if it's lost, existing 2FA registrations become unusable even if the
  database itself is fine. It lives in Vault at `secret/authelia`/`storage-key`,
  deliberately *not* in the routine `external-secret.yml` field list (rotation safety) —
  pull it via a one-off ExternalSecret pointed at that specific property if it's ever
  missing from the live `authelia-secrets` Secret.
- `storage-password`: the Postgres role's own login password — separate from
  `storage-key`, regenerable via `ALTER USER authelia WITH PASSWORD ...` without any data
  loss, unlike `storage-key`.
- Redis has no persistence (`--save "" --appendonly no`) — it's a pure session cache,
  losing it just logs everyone out, not a data-loss event.

## How to restore

Restore the Postgres PVC (CNPG: hibernate via `cnpg.io/hibernation: "on"`, swap the PVC
contents, un-hibernate — never `spec.instances: 0`, CNPG rejects that). Then confirm
`storage-key` in the live Secret matches Vault's copy before declaring it done — a
schema-intact database with the wrong `storage-key` will start and look healthy while
silently being unable to decrypt existing 2FA secrets.

## Known gotchas

- CNPG's Postgres image needs a broad `host all all <pod-cidr> scram-sha-256` line in
  `pg_hba.conf` for pod-to-pod connections — the default template only covers
  loopback/local. If a *fresh* (not restored) instance can't authenticate from another
  pod, check this first.
- OTP notifications use the `filesystem` notifier, not SMTP — codes land in
  `/tmp/notification.txt` inside the pod, not an inbox.
