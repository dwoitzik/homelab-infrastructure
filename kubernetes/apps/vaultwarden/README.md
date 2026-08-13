# Vaultwarden

Self-hosted Bitwarden-compatible password manager. First workload restored after
Vault/ExternalSecrets during the 2026-08-13 disaster recovery — the brief's own
"verify the operator can log in and see their data before building anything else"
requirement.

## Storage

Single PVC (`local-path`, node-pinned), holds `db.sqlite3` (accounts, ciphers,
attachments metadata), `rsa_key.pem` (JWT signing), and the icon cache. `local-path`
because this is small, latency-sensitive, single-writer data — no need for `nfs-client`.

## How to restore

The whole vault lives in `db.sqlite3` + `rsa_key.pem`. Copy both onto the PVC (a
throwaway pod mounting the same claim works) and restart the pod. `sqlite3 db.sqlite3
"PRAGMA integrity_check;"` is a fast sanity check before trusting a restore. Verified
2026-08-13 against the pre-disaster backup: 267 ciphers, 1 user, schema intact.

## Known gotchas

- Client apps (browser extension, mobile) cache their own session/sync state
  independently of the server — after a server-side restore, a stale client can show an
  empty vault even though the web vault (which does a fresh full sync on every login)
  shows data correctly. Fix is a full sign-out + remove-account-and-re-add on the client,
  not just lock/unlock.
- Auth flows through Authelia's `Remote-User` header for SSO where applicable, but
  Vaultwarden also supports its own native login — both paths work.
