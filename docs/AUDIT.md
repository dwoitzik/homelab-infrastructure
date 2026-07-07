# Homelab Infrastructure Audit

**Date:** 2026-06-22
**Scope:** Full repo + live cluster + Proxmox host
**Method:** Static analysis of all manifests, Terraform, and Ansible; live `kubectl` queries;
SSH to `pve-mgmt-01` for Proxmox/ZFS state.

Severity scale: **CRITICAL** (data loss or full outage risk) · **HIGH** (security exposure or
significant reliability gap) · **MEDIUM** (quality debt, partial coverage) · **LOW** (minor
style or hygiene).

---

## 1. Security

### SEC-001 — Hardcoded OIDC client secret in Headscale ConfigMap · **HIGH**

`kubernetes/apps/headscale/config.yml` contains:

```yaml
client_secret: "headscale-pass-2026"
```

This is a plaintext credential in a Git-committed manifest. All other OIDC clients
(Proxmox, PBS, ArgoCD, Grafana) store their client secrets in Vault and inject via
ExternalSecret. Headscale is the only exception.

- **Impact:** Anyone with repo read access (it is public) has the Authelia OIDC client
  secret for the Headscale/Tailscale control plane.
- **Fix:** Move to Vault `secret/headscale`, create an ExternalSecret → Secret, and
  reference via `secretKeyRef` in the Headscale ConfigMap. Rotate the value immediately.
- **Blast radius:** Headscale restart required; Tailscale clients reconnect automatically.
- **Effort:** Small (1–2h).

---

### SEC-002 — Authelia shared OIDC client secret across 4 services · **RESOLVED**

Generated 4 distinct client secrets (proxmox, pbs, argocd, grafana) 2026-06-23, each
hashed independently via `authelia crypto hash generate argon2` run inside the live
Authelia pod. Updated: Authelia's per-client `client_secret` hash in `configmap.yml`;
Vault `secret/argocd#oidc-client-secret` and `secret/grafana#oidc-client-secret` (both
already flow through ExternalSecret -> k8s Secret -> the consuming pod, no plumbing
changes needed); Proxmox's OIDC realm via `pvesh set /access/domains/authelia --client-key
...` and PBS's via `proxmox-backup-manager openid update authelia --client-key ...` (both
fully API/CLI-automatable, no manual UI step needed). `hmac_secret` (the third instance of
the same shared value) rotated independently as part of SEC-003/004.

Verified live: all four services' pods restarted cleanly post-rotation; Proxmox/PBS retain
their `pam`/local-root fallback login and ArgoCD/Grafana retain their local admin account,
so none of this carried real lockout risk.

---

### SEC-003 — Authelia session-secret and storage-key are placeholder values · **RESOLVED** (2026-06-24)

`secret/authelia` `session-secret` = `thisisaverysecretsessionsecret`;
`storage-key` = `thisisaverysecretstoragekey`. Both low-entropy, copy-pasted-looking
values. `jwt-secret` (`thisisaverysecretjwtsecret`) turned out to be the same pattern,
not originally called out, but fixed alongside it.

- **2026-06-23:** `session-secret` and `jwt-secret` regenerated with `openssl rand -hex
  32`, written to Vault, restarted Authelia clean. `storage-key` was deliberately left
  untouched at the time, believed to need extra care via `storage encryption change-key`.

- **2026-06-24, much bigger problem found while finishing this:** rotating `storage-key`
  properly requires Authelia to successfully decrypt existing data with the *old* key
  first. It couldn't — `authelia storage encryption check` reported the configured key
  invalid against the live schema. Root cause: `kubernetes/apps/authelia/configmap.yml`
  set `encryption_key: '/config/secrets/storage-key'` as a bare quoted YAML string. That
  is not a file-path reference Authelia auto-resolves — it's the literal config value.
  **The functional encryption key, this entire deployment's lifetime, has been the literal
  string `/config/secrets/storage-key`** — and the same bug affected `jwt_secret`,
  `session.secret`, and `identity_providers.oidc.hmac_secret`, all written with the same
  bare-path-string pattern (only `oidc-issuer-private-key` used Authelia's actual
  `{{ secret "..." | mindent ... }}` templating function correctly). Since this repo is a
  public portfolio artifact, that means the real JWT/session/OIDC HMAC signing secrets
  have been a publicly-visible string the entire time, not the random values Vault
  appeared to hold.
  - **Investigation mistake, corrected before any real damage:** before finding the root
    cause, the live `encryption`/`totp_configurations` rows were deleted on the (wrong)
    assumption the original key was unrecoverably lost — this would have invalidated the
    one real TOTP enrollment in the database. A `pg_dump` backup had been taken first;
    confirmed the literal-string theory by restoring the backup into an isolated temporary
    database (`authelia_verify_temp`, same Postgres instance, dropped after) and validating
    `authelia storage encryption check` against it with `--encryption-key=/config/secrets/storage-key`
    — succeeded, including the TOTP row. Restored the original rows into production from
    the same backup before making any further changes, then re-verified clean.
  - **Fix:** Changed all four fields in `configmap.yml` to
    `{{ secret "/config/secrets/X" | msquote }}`, Authelia's actual file-templating
    syntax (`X_AUTHELIA_CONFIG_FILTERS=template` was already set on the Deployment).
    Verified correct *before* committing, via an isolated test ConfigMap unmanaged by
    ArgoCD (a live `kubectl apply` of the real fix kept getting silently reverted by
    ArgoCD's `selfHeal: true` until the Git source was actually updated and merged).
  - Ran the real `authelia storage encryption change-key` (now that the true old key —
    the literal path string — was correctly identified) to re-encrypt with a fresh
    `openssl rand -hex 32` value, then updated Vault + the live Secret to match.
    `jwt-secret`/`session-secret`/`hmac-secret` already held real random values from the
    2026-06-23 pass (that rotation just hadn't taken effect yet) — no re-rotation needed,
    just the templating fix so the files actually get read now.
  - Verified live: both Authelia replicas started clean post-merge, `Storage schema is
    already up to date`, serving auth traffic normally, TOTP enrollment intact.
- **Effort:** Was small; became large once the templating bug surfaced. Done.

---

### SEC-004 — Cross-service secret reuse: redis-password and storage-password · **RESOLVED**

Both `redis-password` and `storage-password` shared the same value as the Paperless
Postgres password (`TD3fAJ2s1cxJ`). Generated two new, independent random values
2026-06-23:

- `redis-password`: updated the `redis-secret` k8s Secret (manually managed, not
  ExternalSecret-sourced) and restarted `redis-authelia` so its `--requirepass` picks up
  the new value, then updated Vault `secret/authelia#redis-password` to match and
  restarted Authelia.
- `storage-password`: ran `ALTER USER authelia WITH PASSWORD ...` directly against the
  live `postgres-authelia` (CNPG) instance, then updated Vault to match. Deliberately
  **not** added to Authelia's ExternalSecret (see comment in `external-secret.yml`) — if
  it synced automatically from a future Vault-only edit, Authelia's DB connection would
  break until someone remembered the matching `ALTER USER` step. Both sides must be
  rotated together, manually, going forward.

Found but not fixed: `postgres-authelia` (CNPG cluster) is itself on the `nfs-client`
StorageClass — flagged as REL-010, a lower-urgency cousin of GIT-006 (Postgres has its
own robust locking, unlike SQLite/BoltDB, but NFS is still not its recommended storage).

---

### SEC-005 — Container images pinned to `:latest` or floating tags · **RESOLVED** (2026-06-28)

**2026-06-27 (batch 1):** Renovate's Kubernetes manager was not configured at all — only Helm/Terraform
managers were active, so none of the 93 container images in `kubernetes/` were being tracked.
Added `"kubernetes": {"fileMatch": ["kubernetes/.+\\.yml$"]}` to `renovate.json` (PR #168).
Renovate immediately detected all images and opened PRs for outdated ones.

Additionally pinned the remaining major-only floating tags (PR #187):

- `louislam/uptime-kuma:1` → `1.23.17`
- `redis:7-alpine` → `7.4.9-alpine` (redis-authelia, redis-nextcloud)
- `redis:7` → `7.4.9` (redis-paperless)
- `postgres:16` → `16.14` (paperless)
- `postgres:16-alpine` → `16.14-alpine` (nextcloud)
- `nextcloud:30-apache` → `30.0.17-apache`

Removed dead `keel.sh/policy: force` / `keel.sh/trigger: poll` annotations from uptime-kuma
(Keel is not deployed; annotations had no effect).

**2026-06-28 (batch 2, PR #193):** Pinned all remaining floating/non-semver tags:

- `valkey/valkey:9-alpine` → `9.1.0-alpine` (Immich cache)
- `gotenberg/gotenberg:8` → `8.34.0` (Paperless addon)
- `ghcr.io/renovatebot/renovate:43` → `43.245.0`
- `gitea/gitea:1.26` → `1.26.4`
- `hashicorp/vault:1.21` → `1.21.4` (unseal sidecar)
- `ghcr.io/home-assistant/home-assistant:stable` → `2026.6.4` (`:stable` is a moving tag)
- `ghcr.io/open-webui/open-webui:main` → `v0.9.6` (`:main` was a mutable branch tag — worst offender)
- `alpine:3` → `3.22` (sysctl-fix init container)

All 93+ container images in `kubernetes/` are now fully semver-pinned. Renovate opens PRs
for all future updates automatically. No remaining `:latest` or floating tags.

---

### SEC-006 — Kyverno resource-limits and no-latest-tag policies in Audit mode · **RESOLVED**

Flipped both to `Enforce` 2026-06-23 after confirming zero PolicyReport violations
cluster-wide. Found and fixed two real bugs in the policies along the way:

- `disallow-latest-tag`'s `message` field referenced `{{ element.image }}` outside the
  `foreach` it was defined in — Kyverno's policy admission webhook itself now rejects
  that (newer Kyverno validates this at policy-creation time); moved the message to a
  non-element-specific form at the rule level instead.
- `require-resource-limits`'s deny condition (`element.resources.limits | length(@)`)
  crashed with a JMESPath type error under Kyverno's `autogen` controller (which
  auto-generates an equivalent Deployment/StatefulSet-level rule from the Pod-level one) —
  unlike `disallow-privileged-containers`' condition, it had no `|| <default>` fallback
  for a field that's legitimately absent in the autogenerated evaluation context.
  Rewrote as two explicit `element.resources.limits.cpu || ''` / `.memory || ''` checks,
  matching the safe pattern the privileged-containers policy already used.

Verified with a deliberate negative test (a bare Pod with no `resources:`) — correctly
rejected by the admission webhook.

---

### SEC-007 — Proxmox provider uses insecure TLS (`insecure: true`) · **RESOLVED** (2026-07-06)

`terraform/stacks/proxmox/providers.tf` set `insecure = true` — skipped TLS certificate
verification when talking to the Proxmox API.

- **Impact:** On the local management VLAN this is low risk, but it means MITM on VLAN 10
  could intercept API calls including the API token.
- **Fix:** Proxmox's cluster cert already carries an IP SAN for `10.0.10.10` (confirmed
  via `openssl s_client`), so no re-issuance was needed — just trust. Built a custom
  Atlantis Docker image (`ansible/roles/atlantis/files/Dockerfile`) layering in
  Proxmox's self-signed cluster CA via `update-ca-certificates`, based on the existing
  `atlantis_image` tag so Renovate bumps keep working unmodified. Flipped `insecure`
  to `false`.
- **Verified live:** rebuilt/redeployed the Atlantis container, confirmed the CA landed
  in `/etc/ssl/certs`, confirmed `wget --spider https://10.0.10.10:8006` succeeds with
  verification on. Real end-to-end proof: PR #293's `atlantis/plan: proxmox` check
  passed — "No changes. Your infrastructure matches the configuration" — with
  `insecure = false` live against the real Proxmox API.
- **Effort:** Small — done.
- **Investigated but not applied to MikroTik's identical `insecure = true`
  (`terraform/stacks/network/providers.tf`)**: RouterOS's self-signed cert at
  `10.0.10.1` has `Subject: CN = 10.0.10.1` but **no SAN extension at all**
  (confirmed via `openssl s_client`). Go's TLS stack (used by the terraform-routeros
  provider) stopped honoring bare CN matching in Go 1.15+ — trusting the CA alone
  would not be enough, RouterOS itself would need to be issued a new self-signed cert
  with a proper IP SAN first. That means touching the live router's own certificate
  config on a production network device that's a documented single point of failure —
  materially higher blast radius than the Proxmox fix for a LOW-severity finding, and
  outside what the `routeros` Terraform provider manages declaratively (would need
  RouterOS console/API commands directly). Left as accepted risk; revisit only with a
  dedicated maintenance window.

---

### SEC-008 — Atlantis had zero authentication and was reachable over plain HTTP · **CRITICAL** (fixed 2026-06-23)

Found while auditing Authelia coverage across all `IngressRoute`s (prompted by a request to
harden privacy/security across the board, not Atlantis-specific). Of 28 `IngressRoute`s,
`atlantis-final` was the only one with `entryPoints: [web, websecure]` — reachable over
unencrypted HTTP, not just HTTPS — and the only one with **no auth layer of any kind**: no
Authelia middleware, no `ATLANTIS_WEB_BASIC_AUTH`/username/password env vars on the
Deployment. Confirmed live: `curl -sk https://atlantis.woitzik.dev/` returned the full
Atlantis UI (PR list, plan history, repo config) with a plain `200`, no redirect to Authelia,
no password prompt.

- **Impact:** Atlantis holds the credentials and drives `terraform apply` for the entire
  homelab (Proxmox root-capable API token, MikroTik router credentials, AWS/Garage S3 keys —
  all visible to it as env vars, and plan output can echo non-`sensitive`-marked values).
  Anyone who could reach `atlantis.woitzik.dev` — any device on the LAN, or the internet if
  the domain resolves publicly — could view full Terraform plan/apply history and repo
  config with zero credentials required.
- **Why it wasn't just "add Authelia and move on":** Atlantis's GitHub webhook (`POST
  /events`, used to trigger plan/apply from PR comments) is itself authenticated via
  `ATLANTIS_GH_WEBHOOK_SECRET` (HMAC signature) — gating the whole host behind Authelia's
  forward-auth would have broken GitHub's webhook delivery, silently killing the entire
  GitOps Terraform workflow.
- **Fix (2026-06-23):** Split `atlantis-final` into two routes in
  `kubernetes/system/apps-ingressroute.yml`: `Host(...) && PathPrefix(/events)` (priority
  10, no middleware — webhook keeps its own HMAC auth) and the catch-all `Host(...)`
  (priority 1, `authelia` middleware — same pattern as every other internal tool). Also
  dropped the `web` entrypoint so it's `websecure`-only like every other service.
- **Blast radius:** UI access now requires an Authelia session; GitHub webhook delivery
  unaffected (still hits `/events` directly, still HMAC-verified).
- **Effort:** Small (1h) — done.

**Regression, found and fixed again 2026-07-05 (PR #288):** ADR-012's migration of
Atlantis off k3s onto its own LXC (`ct-srv-atlantis-01`, 10.0.20.250, see REL-036)
deleted the `atlantis-final` IngressRoute entirely — the Authelia gate went with it —
and repointed the Cloudflare Tunnel ingress (`terraform/stacks/cloudflare/main.tf`)
straight at the LXC's IP, bypassing Traefik (and Authelia) completely. Found during a
user-requested security review of public-facing tunnels. Confirmed live via a public-DNS
bypass test (`dig @1.1.1.1` for the real IP, then `curl --resolve` through the actual
Cloudflare edge rather than the sandbox's internal split-horizon DNS): `atlantis.woitzik.dev`
served its full UI (PR history, plan/apply state, lock controls) to a plain unauthenticated
request over the real public path, `cf-ray`/`server: cloudflare` headers confirmed present.

- **Fix:** Recreated the same external-host-behind-Traefik-+-Authelia pattern already
  used for `pve-final`/`pbs-final` (`kubernetes/system/apps-ingressroute.yml`):
  a selector-less Service+Endpoints (`external-atlantis` → 10.0.20.250:4141) plus an
  `atlantis-final` IngressRoute with `/events` split out unauthenticated (webhook HMAC
  is its own auth) and everything else behind `authelia`. Repointed the Cloudflare Tunnel's
  `service` from the LXC's raw IP to Traefik's `websecure` (443) entrypoint with
  `origin_server_name = "atlantis.woitzik.dev"` (needed because Traefik's cert doesn't
  match the internal `traefik.kube-system.svc.cluster.local` service hostname cloudflared
  otherwise expects).
- **Lesson: any infra migration that changes how a public hostname reaches its backend
  (new LXC, new Service, new tunnel target) needs an explicit ingress/auth re-audit** —
  the auth gate lived on the now-deleted IngressRoute, not on Atlantis itself, so moving
  the backend silently moved the exposure back to "fully public" with no error or warning
  anywhere in the migration. Same broader theme as REL-042/044's "Application manifest
  never re-synced after bootstrap" class of bug: a security control that isn't itself
  continuously reconciled/verified live can silently stop existing.
- **Verified fixed:** re-ran the same public-DNS-bypass curl test post-fix — correct
  `302` redirect to `auth.woitzik.dev`.

---

### SEC-013 — Garage `rpc_secret`/`admin_token` leaked in git history were still the live values · **RESOLVED** (2026-07-06)

Found while investigating `.gitleaks-baseline.json` (flagged in the 2026-07-05 security
review as needing a check). The baseline exists to suppress historical findings from CI,
but "historical" only means "the file no longer contains it" — it says nothing about
whether the *value itself* was ever rotated. Of the ~15 unique secrets baselined,
checked each against the current live Vault/config value; two were **byte-identical to
the value still live in production**:

- Garage `rpc_secret` (`secret/garage#rpc-secret`) — used for internal cluster RPC auth.
- Garage `admin_token` (`secret/garage#admin-token`) — full control of Garage's Admin API
  (the S3 backend for Terraform state, Velero backups, and Immich photo storage).

Both had been sitting in git history, in a **public repository**, unrotated since the
commit that first added them (2026-06-03), fully readable by anyone with repo access —
the baseline only stopped CI from re-flagging them, it did nothing to reduce actual
exposure.

Everything else checked in the same pass was already safe: Authelia's OIDC private key
and `hmac_secret` differ from their leaked git-history values (rotated under SEC-003),
the Cloudflare tunnel token differs from its leaked value (rotated under REL-048's
predecessor work), Headscale's `client_secret` is already Vault/ExternalSecret-sourced
(SEC-001), and the Minio/mikrodash secrets belong to files no longer present in the tree
at all (superseded configs, no live counterpart to rotate).

- **Fix:** Generated fresh random values (`openssl rand -hex 32`/`-hex 16`), wrote them to
  `secret/garage` in Vault, force-synced the `garage-secrets` ExternalSecret
  (`kubectl annotate externalsecret garage-secrets -n apps force-sync=... --overwrite`
  to trigger an immediate reconcile instead of waiting out the 1h `refreshInterval`), then
  `kubectl rollout restart deployment garage`.
- **Verified live:** new pod came up with 0 restarts, `garage status` showed the single
  node healthy and connected via RPC (proves the new `rpc_secret` actually works, not
  just that the pod started), `s3.woitzik.dev` still answering. Grepped the whole repo
  for both old values — no other file references them outside
  `.gitleaks-baseline.json` itself (which is left as-is; it's a historical detection
  record, not a live config, and removing entries from it doesn't add security — the
  values are already rotated and useless to an attacker now).
- **Lesson: a `.gitleaks-baseline.json` (or any allowlist/baseline suppressing historical
  secret-scanner findings) needs a recurring "is this value still live" check, not just a
  one-time "yes it's in history, baseline it and move on."** A baseline is correct for
  genuinely-rotated-already secrets; silently baselining a still-active one just
  documents the exposure instead of closing it.
- **Not found live** (checked but not re-verified in exhaustive depth): the RSA private
  key baselined from `authelia_cm.tmp`/an old `configmap.yml` commit differs from the
  current Vault value in its trailing bytes, which is enough to conclude it isn't the
  identical string, but a full OIDC key rotation (re-issuing tokens, updating RP-side
  JWKS caches for Proxmox/PBS/ArgoCD/Grafana) was out of scope for this pass since the
  live value is already different from the leaked one.

---

### SEC-014 — Authelia's `users_database.yml` (real password hash) was a plain committed Secret · **RESOLVED** (2026-07-06)

Same class as SEC-001/SEC-003: `kubernetes/apps/authelia/users_database_secret.yml` was
a static `kind: Secret` with the base64-encoded `users_database.yml` file committed
directly to this public repo — including the real argon2 hash of the admin login
password used across the entire Authelia SSO layer (Proxmox, PBS, ArgoCD, Grafana,
Headscale, and every Authelia-gated app in `apps-ingressroute.yml`).

- **Fix (storage only):** Migrated to an ExternalSecret sourced from
  `secret/authelia#users-database-yml` in Vault, matching the existing `authelia-secrets`
  pattern. Same hash value as before — verified byte-identical live before committing,
  `auth.woitzik.dev` still serving login normally, no Authelia pod restart triggered.
  This closes the "committed in git" half of the finding.
- **Fix (password rotation, done same day with explicit user sign-off):** the password
  itself had been sitting as a crackable offline hash in a public repo's git history for
  weeks — moving *where* it's stored didn't undo that past exposure on its own. Generated
  a new random password, hashed it live via `authelia crypto hash generate argon2` inside
  the running pod (never touched a plaintext value outside that one command), wrote the
  new hash to `secret/authelia#users-database-yml` in Vault, force-synced the
  ExternalSecret, and `kubectl rollout restart deployment authelia`. New password
  communicated to the user directly (not committed anywhere).
- **Verified live:** both Authelia replicas restarted clean, `auth.woitzik.dev` serving
  login normally post-rollout.
- **Effort:** Small — done.

---

### SEC-015 — Live MikroTik `terraform` API user password hardcoded in a bootstrap script · **RESOLVED** (2026-07-06)

Found during a portfolio-quality pass over the repo root (prompted by "what would an
employer/reviewer flag in this repo"). `network/scripts/bootstrap.rsc` — a one-time
router bootstrap reference script, not something re-run regularly — had the router's
`terraform` API user's password hardcoded in plaintext:
`password="***REMOVED***"`. Confirmed live via a direct authenticated REST call to the router's `/rest/user`
endpoint (returned `200`) that this was **still the real, active credential** — not a
stale placeholder. This user's group
(`terraform-api`) grants `read,write,api,rest,test,winbox` — full network-management
API access to the router that runs this entire homelab's firewall/NAT/VLANs. It had
been sitting in a public repo's git history since the file was first committed
(2026-03), unrotated, and outside the scope of the earlier `.gitleaks-baseline.json`
sweep (SEC-013) since this file/pattern was never flagged by gitleaks at all.

- **Why I couldn't rotate it myself:** the `terraform` user's live group policy
  correctly denies both `password` and `sensitive` (`!password,!sensitive`, confirmed
  via `GET /rest/user/group`) — meaning this user structurally cannot change its own
  (or anyone's) password via the API. Good security posture, but it also meant a
  `PATCH /rest/user/*` attempt failed with `not enough permissions (9)`. No admin
  credential exists in Vault, and this user was never brought under Terraform's own
  management (no `routeros_user` resource exists for it) — so there was no automated
  path to rotate it. The user rotated it directly via Winbox/SSH as `admin`.
- **Fix:** verified the new password live (`200` on the new credential, `401` on the
  old one), updated `ansible/group_vars/all/vault.yml` to match, redeployed the
  Atlantis LXC (`ansible-playbook site.yml --limit atlantis_nodes`), and replaced the
  hardcoded value in `bootstrap.rsc` with a placeholder + a comment instructing any
  future re-run to set the password out-of-band, never commit a real value.
- **Verified end-to-end:** this PR's own `atlantis/plan` check against
  `terraform/stacks/network` succeeding is the real proof the new credential works —
  a `terraform validate`/`fmt` pass alone would not catch a wrong or unrotated
  credential.
- **Lesson:** the gitleaks baseline sweep (SEC-013) checked *known-flagged* secrets
  against their live values, but a secret that gitleaks' generic-api-key/generic-secret
  rules never pattern-matched in the first place (a `.rsc` RouterOS script isn't a
  typical scanned extension/pattern) can sit invisible to that whole class of tooling
  indefinitely. A portfolio-quality pass that manually walks the repo root and asks
  "would a reviewer's eyes catch this" found what an automated secret scanner missed.
- **Not done:** bringing the `terraform` RouterOS user itself under Terraform
  management (a `routeros_user` resource) so its credential lifecycle is
  declarative/tracked like everything else this stack manages — worth a follow-up, not
  attempted here given the live-router blast radius of experimenting with the very
  credential Terraform authenticates with.
- **Effort:** Small once the user could rotate the live credential — done.

---

### SEC-009 — Home Assistant had no auth layer beyond its own login · **MEDIUM** (fixed 2026-06-23)

Same Authelia-coverage audit as SEC-008. Of the apps with no Authelia middleware,
`nextcloud-final` and `gitea-final` are deliberate (CalDAV/CardDAV and git protocol clients
need direct unauthenticated-at-the-edge access, both already commented in
`apps-ingressroute.yml`); `ha-final` had no such comment and no documented reason — it was
just relying on Home Assistant's own login.

- **Fix:** Added the `authelia` middleware to `ha-final`, same pattern already used for
  Jellyfin (`media-final`): Authelia gates the web UI, Companion app users should connect
  via the Headscale VPN for direct local access instead of the public hostname.
- **Blast radius:** Browser access to `ha.woitzik.dev` now requires an Authelia session
  first. If the HA Companion app was configured against the public URL directly (not
  via Headscale), it will need reconfiguring.
- **Effort:** Small — done.

---

### SEC-010 — GitHub "Security and quality" tab: 545 open Code Scanning alerts · **PARTIAL** (2026-06-24)

User-reported, not self-discovered: GitHub's Security tab showed 545 open Trivy
findings against `kubernetes/`. My API token lacks the `security_events` scope needed
to read code-scanning/secret-scanning alerts directly (confirmed via a live 403 on
both endpoints) — worked from a screenshot instead.

- **Root cause of the volume:** ~20 Deployment/StatefulSet/DaemonSet manifests across
  this repo have **no `securityContext` at all**. Each container missing one trips
  roughly a dozen separate Trivy rules (KSV-0001, 0003, 0004, 0012, 0014, 0020, 0021,
  0030, 0104, 0118, etc. — confirmed by running `trivy config` locally against
  individual files), which accounts for the bulk of the count.
- **Two findings were genuinely justified, not oversights** — confirmed by running
  `trivy config` locally to get exact rule IDs, then suppressing precisely those
  IDs+paths via a new `.trivyignore` (flat format with `path:` scoping — note: a
  `.trivyignore.yaml` structured-format attempt first did NOT work for misconfigurations,
  only the plain `.trivyignore` does):
  - `sysctl-fix` DaemonSet (`KSV-0009/0010/0017/0118`): genuinely needs hostNetwork,
    hostPID, and privileged to reach the host's sysctl namespace — there's no less-
    privileged way to do this from inside a container.
  - SABnzbd's Mullvad kill-switch init container (`KSV-0022/0120`): genuinely needs
    NET_ADMIN (create the wg0 interface) and SYS_MODULE (load the wireguard kernel
    module) for a WireGuard tunnel to come up at all.
- **Follow-up done in SEC-012** (below): the `securityContext` hardening pass across
  these ~20+ manifests, including a live incident caused by that pass and its recovery.

### SEC-012 — securityContext hardening pass across ~25 manifests, including a self-inflicted outage and recovery (2026-06-24)

Follow-up to SEC-010. Added `securityContext` to every container in `kubernetes/`
that was missing one (also deleted `kubernetes/test-app/`, an undeployed leftover
ArgoCD smoke-test manifest with no remaining purpose). Reduced Trivy config
misconfiguration findings from 215 to 171.

**What went wrong, and why this is left in instead of cleaned up:** the first pass
(PR #94) added `capabilities.drop: [ALL]` and, on some containers, `runAsNonRoot: true`
based on assumptions about each image's default user and entrypoint behavior, verified
only via `kubeconform` (schema-valid, not behavior-valid) before merging. Within minutes
of merge, ArgoCD's auto-sync (selfHeal is on — merge is deploy in this repo) rolled out
the change and **nine containers broke**, including both Postgres instances backing
Paperless and Nextcloud (real outage, not just a degraded non-critical service):

| Failure mode | Root cause | Affected |
|---|---|---|
| Crash-loop on chown/su-exec failure | `capabilities.drop:[ALL]` removed CAP_CHOWN/CAP_SETUID/CAP_SETGID that the image's entrypoint needs to drop from root to its runtime user before exec'ing the real process | gitea, authelia, headscale, mealie, postgres (paperless + nextcloud), redis (paperless + nextcloud — only the instances *without* a `command:` override that bypasses the entrypoint; redis-authelia's explicit `command: redis-server ...` skips that entrypoint entirely and was unaffected) |
| `CreateContainerConfigError`, container never starts | `runAsNonRoot: true` assumed several images default to a non-root user when they don't | vault-unseal (hashicorp/vault), redis-nextcloud, redis-paperless, cloudflare-ddns (curlimages/curl) |

Caught within ~15 minutes by directly inspecting pod status/logs after forcing an
ArgoCD hard-refresh (its poll interval otherwise meant `kubectl get application`
showed stale "Synced/Healthy" against an old revision — checking `Application` sync
status alone is **not sufficient** to confirm a change is actually live; always check
the pod's own `creationTimestamp` and the live Deployment/StatefulSet spec). Two more
of the same failure mode (paperless-ngx's `init-folders` needing CAP_CHOWN, uptime-kuma's
entrypoint needing CAP_SETGID/CAP_SETUID) surfaced only on a slower ReplicaSet rollout
and were caught during an extended verification pass ~30 minutes later — a reminder that
"Running with N restarts looking survivable" isn't proof of health; a clean
`creationTimestamp` with 0 restarts since is. Fixed across five follow-up PRs (#95
gitea, #96 the bulk of it, #97 a redis-specific root cause found verifying #96, #99
paperless-ngx + uptime-kuma found in the extended pass) as the actual failure modes
were confirmed live, one container at a time — `kubectl logs` on the crashing container
told the real story every time (`chown: Operation not permitted`, `su-exec: setgroups:
Operation not permitted`, `setpriv: setresuid failed`/`setgroups failed`).

A second trap during recovery: manually `kubectl apply`-ing the fixed YAML directly
(to restore service faster than a PR cycle) got **silently reverted by ArgoCD's
selfHeal**, which kept re-applying the still-broken git state until the actual fix
landed on `main`. In this repo, with selfHeal on, **git is the only place a fix can
actually stick** — a manual kubectl fix during an incident buys nothing once selfHeal
notices the drift.

Final state: `allowPrivilegeEscalation: false` applied everywhere (safe, always-on
baseline). `capabilities.drop: [ALL]` kept only where verified to not break the
container's entrypoint. `runAsNonRoot: true` kept only where the image's default user
is verifiably already non-root (e.g. cloudflared, confirmed live). Each reverted file
has an inline comment recording the specific verified failure mode, so this isn't
re-attempted blindly later.

**Lesson for any future blanket securityContext/PodSecurity change in this repo:**
`kubeconform`/`kubectl --dry-run` only validate schema, not runtime behavior —
container entrypoints that do their own privilege-dropping (chown + su-exec/setpriv,
common in postgres, redis without a command override, gitea, authelia, mealie,
headscale) need `CAP_CHOWN`/`CAP_SETUID`/`CAP_SETGID` and cannot run with all
capabilities dropped, regardless of what the final running process needs. Verify
each app's actual startup behavior live before merging, not just that the YAML
parses.

- **Also separately noted:** the GitHub repo sidebar's "Contributors" widget was still
  showing a stale "claude" entry from before this session's git-filter-repo history
  rewrite — verified clean across every branch/ref via `git log --all -p | grep -i
  co-authored-by` (zero hits) and the `/contributors` API (only `dwoitzik`). This is
  GitHub's own cached contributor-graph computation, which is documented to lag behind
  actual repository state after a force-push rewrite — no user-facing way to force a
  refresh.
- **Effort:** Small for the two justified suppressions (done); medium-large for the
  real `securityContext` hardening pass across ~20 files (not done).

---

## 2. Reliability / Recoverability

### REL-001 — 2 of 3 k3s nodes stopped; cluster running single-node · **RESOLVED** (2026-06-23)

Originally: Proxmox live state had `vm-srv-k3s-12` and `vm-srv-k3s-13` stopped, with
`vm-srv-k3s-11` carrying the whole cluster alone. The original fix proposal (start all
three as embedded-etcd members for HA) was attempted and **reverted** — running 3
concurrent etcd writers on VMs that all share one physical host and one ZFS pool produced
enough I/O contention to freeze the host repeatedly (see `docs/compute-nodes.md`).

- **Current state:** All three nodes run continuously with `on_boot = true`.
  `vm-srv-k3s-11` is the sole control-plane + etcd server; `-12`/`-13` are agent-only
  workers, adding compute capacity without adding etcd writers. This is a deliberate
  single-server design, not an oversight — see `docs/k3s-architecture.md` §1.
- **Residual risk (accepted, not a bug):** `mini` (the physical host) remains a single
  point of failure either way — 3-way HA on one host/one disk was never actually safe.
  Target is fast *recovery* via `DISASTER-RECOVERY.md`, not zero-downtime HA.
- **Known follow-up, not yet done:** the Keepalived VIP (`10.0.20.10`) still lists
  k3s-12/13 in its failover priority from the old 3-master design even though they no
  longer run the API server — see `docs/k3s-architecture.md` §1 caveat.

---

### REL-002 — PBS backup server stopped; last VM backup was April 30, 2026 · **RESOLVED** (2026-06-23)

Originally: `ct-mgmt-pbs-01` was stopped, last successful VM backup was 7+ weeks stale,
and the k3s VMs (211/212/213) plus the NFS LXC (220) were not even in the PBS backup job's
scope.

- **Current state (verified live 2026-06-23):** `ct-mgmt-pbs-01` is running with
  `onboot=1`. The backup job (`backup-8b6a6f73-c4ce`, schedule `0 3 * * *`) uses `all: 1`,
  covering every VM/CT on the host including all three k3s VMs and the NFS LXC. The
  03:00 run completed successfully this morning (2026-06-23, 03:00–03:41) with retention
  keep-daily=7/keep-last=3/keep-weekly=4.
- **Residual gap:** PBS datastore is local to `mini` (2TB USB HDD) with rclone→Google
  Drive offsite — see `docs/backup-strategy.md`. No independent verification/alerting
  (e.g. healthchecks.io) on backup job success is wired up yet; failures would currently
  only be noticed by manually checking PBS.

---

### REL-003 — Velero S3 backend (Garage) is in-cluster; circular dependency on recovery · **HIGH**

Velero backups are stored in Garage S3, which itself runs as a k3s pod. If the cluster is
lost entirely (not just a namespace failure), Garage goes down with it, making the Velero
backups unreachable until Garage is restored — but restoring Garage requires the cluster
to be up.

The offsite backup to Cloudflare R2 (`daily-offsite` schedule) would break this dependency,
but it is **not yet active** — waiting on R2 Account ID and API token.

- **Impact:** Full cluster loss → Velero backups inaccessible until the cluster is rebuilt
  enough to run Garage again. Recovery is possible but more complex than it should be.
- **Fix:** Provide R2 credentials and activate `velero-r2-credentials` Secret and the
  `daily-offsite` Schedule. This is the missing third copy in the 3-2-1 rule.
- **Effort:** Small once R2 credentials are in hand (30 min).

---

### REL-004 — NFS server is a single point of failure for all PVCs · **HIGH**

All k3s PVCs (except `uptime-kuma-data` which uses `local-path`) are backed by
`ct-srv-nfs-01`. If NFS goes down (LXC crash, NFS daemon hang, host issue), every
stateful pod in the cluster loses its volume simultaneously.

The NFS server's data lives on `rpool/nfs-data` (ZFS on the single NVMe SSD). ZFS
protects against corruption, not disk failure.

- **Impact:** Full data unavailability for all stateful apps (Nextcloud, Vaultwarden,
  Paperless, Postgres, etc.) until NFS is restored. No automatic failover.
- **Fix (short term):** Add NFS healthcheck to Uptime Kuma; set `onboot=1` for
  `ct-srv-nfs-01` (it's currently `onboot=0`).
- **Fix (long term):** Consider a second NFS export from the host directly (as a warm
  standby), or migrate critical PVCs to CNPG WAL archiving + Velero for independent recovery.
- **Effort:** Short-term is minutes; long-term is significant.

---

### REL-005 — rpool data volume at 70% utilization · **RESOLVED** (2026-06-25, via REL-019)

`rpool/data`: 292 GB used, 129 GB available (out of ~420 GB). The AI LXC alone uses 43 GB
(`subvol-201-disk-0`) and the Docker LXC uses 16 GB. With k3s VMs each using 72–74 GB of
the 120 GB allocated, available space will tighten as workloads grow.

- **Impact:** When rpool fills, ZFS writes fail, which freezes the host. This contributed
  to the June 2026 freeze investigation.
- **What actually happened:** this is exactly what occurred in REL-019 (2026-06-25) --
  rpool filled completely (96-100%), paused all three k3s VMs on disk I/O error. Root
  cause was Garage's ~176GB living on rpool plus Velero backing it up into itself.
- **Fix, finally done:** Garage's data migrated to the archive pool (REL-019). rpool is
  now at 60% utilization (was stuck at 70-100% the whole time this finding sat open).
  The recommended alert ("Alert when rpool exceeds 80%") is now live:
  `ProxmoxStorageCapacityHigh`/`Critical` in
  `kubernetes/system/monitoring/storage-capacity-alerts.yml`.
- **Lesson:** this finding was identified and correctly diagnosed back on 2026-06-23/24
  but left as "Medium effort, todo" for two days while the underlying disk kept filling
  -- it eventually caused a full incident (REL-019) and very likely was the actual root
  cause of REL-012's etcd flapping the whole time too. A HIGH-severity capacity finding
  with a known fix and no alert in place shouldn't sit open this long next time.

---

### REL-012 — k3s control plane (etcd) crash-looping all day, 39 restarts · **PARTIAL, likely improved** (discovered live 2026-06-23, alerting added 2026-06-24, root cause possibly addressed 2026-06-25 -- see update below)

Caught live while checking the homepage dashboard: `kubectl` against the API VIP and
against `vm-srv-k3s-11` directly both got connection-refused. SSH'd in and found
`k3s.service`'s systemd restart counter at 39 for the day, restart timestamps spread from
13:52 through 20:54 (roughly every 1-2h). The cluster recovered on its own within ~2
minutes each time — by the time this was investigated, nodes were `Ready` again — but it
has been silently flapping all day with nothing alerting on it.

Root cause (from `journalctl -u k3s` right before each failure): etcd `apply request took
too long` warnings up to **14.3 seconds** (expected: 100ms) on simple read-only range
requests, causing the controller-manager's leader-election lease renewal to time out
(`context deadline exceeded`), which is fatal to the k3s process (`exit code 1`) and
triggers a systemd restart. This is single-node etcd (deliberately, see GIT topology
notes) being starved of disk I/O badly enough to blow through raft's read-index timeout.

- **Likely contributing factor:** `rpool` is at 70%+ utilization (REL-005, already flagged
  but not fixed) on the single shared NVMe behind every VM/LXC on `mini`. High utilization
  degrades NVMe write latency, and this is the same physical disk class previously
  implicated in the documented ZFS/host-freeze investigation (`docs/OPERATIONS.md`).
  Today also had unusually heavy concurrent activity across LXCs (Ollama CPU inference
  stress-testing, paperless-gpt batch processing, NFS LXC near-OOM earlier) which may have
  compounded disk/CPU contention on the shared host at the same time.
- **Impact:** Every one of these episodes is a full control-plane outage (API server
  unreachable, no scheduling, no kubectl) lasting roughly 1-2 minutes, recurring multiple
  times per day, completely silently — no alert fired despite Blackbox/Prometheus already
  monitoring most services. The 39-restart count alone makes this more severe than several
  other CRITICAL-tier findings in this doc.
- **Fix:** (1) **Done 2026-06-24** — added `KubeAPIServerDown` (`up{job="apiserver"}==0`)
  and `KubeAPIServerHighLatency` (p99 request duration >5s) alerts
  (`kubernetes/system/monitoring/control-plane-alerts.yml`), `severity: critical` so they
  route to Discord. Finding this gap also surfaced REL-014 — the *existing* SLO/hardware
  alert rules had never been evaluated either, a separate and arguably worse problem
  than just missing this one alert. (2) Resolve REL-005 (free up rpool headroom) as a
  likely contributing factor — confirmed still at 82.5% as of 2026-06-24, not improved.
  (3) **Checked, not worth doing** — `etcdctl defrag` was on the original list, but
  `etcdctl` isn't installed anywhere on `vm-srv-k3s-11` (k3s embeds etcd without
  shipping the standalone CLI), and the actual DB is only 49MB despite 24 days without
  compaction — not bloated at all. Defrag's benefit here would be negligible, and it
  doesn't address the real root cause (shared NVMe I/O contention) anyway, so
  downloading an unmanaged binary onto the production control-plane node for this
  wasn't worth the risk. Took an `etcd-snapshot save` first regardless, in case this
  gets revisited. Moving etcd's WAL to a less-contended disk if one becomes available
  — still not done, no spare fast disk exists on `mini` right now.
  (4) Re-evaluate whether single-node etcd on this hardware needs a lower `--etcd-arg`
  heartbeat/election-timeout tolerance, or whether the real fix is just less disk
  pressure — not yet done. Confirmed live 2026-06-24 this is still actively recurring
  and getting worse, not better: 87 restarts (up from 39 the prior day), 407 "apply
  request took too long" warnings in just a 6-hour window, with latencies up to 10.8s
  observed directly while investigating this. Checked again later the same day during a
  calmer window: 0 such warnings in a 30-minute span — confirms this tracks disk
  contention from concurrent activity elsewhere on `mini`, not a constant condition.
- **Effort:** Alerting is small (1-2h); root-causing the I/O contention properly is
  larger and probably needs to wait for calmer conditions to test against (it's hard to
  diagnose disk contention while intentionally generating disk contention).
- **Update 2026-06-25, after REL-019:** REL-005's `rpool` utilization (the "likely
  contributing factor" above, confirmed unimproved at 82.5% as of 2026-06-24) is now at
  60% (was 96-100% during REL-019's crisis) after Garage's ~176GB data migrated off
  `rpool` onto the archive pool. `journalctl -u k3s | grep "apply request took too
  long"` counts by hour, measured right after: 4h ago (during the crisis) 1608, 3h ago
  337, 2h ago 23, 1h ago 2 -- a clean trend tracking exactly with the migration
  timeline, not a random fluctuation. Current `zpool iostat` is calm (single-digit
  MB/s). **Not marking this RESOLVED yet** -- this doc already recorded one prior false
  calm window (0 warnings in 30 minutes on 2026-06-24, with the problem recurring
  again later that same day), so one hour of clean data isn't enough on its own. If
  this holds over the following days without intentionally generating disk load, the
  likely conclusion is that REL-012 was never an independent problem -- it was REL-005
  (which was itself downstream of REL-019's actual root cause, Garage living on the
  wrong pool) the whole time. Revisit and downgrade to RESOLVED if the warning rate
  stays low through a normal day's activity (Velero's daily-backup running, etc.).

---

### REL-014 — Every custom PrometheusRule in this repo was silently never evaluated · **RESOLVED** (2026-06-24)

Found while adding the alerting REL-012 calls for ("should have paged immediately") --
went to verify the new alert actually loaded in Prometheus and it didn't show up in
`/api/v1/rules` at all. Checked the two *existing* custom rule files
(`homelab-slo-alerts`/`homelab-slo-recording-rules` and `homelab-hardware-temp-alerts`)
the same way: **neither had ever been loaded either**, despite both being merged days
ago and `ROADMAP.md` claiming the SLO definitions were done.

- **Root cause:** the Prometheus custom resource's `ruleSelector` requires
  `release: kube-prometheus-stack` (confirmed by checking the label on a chart-managed
  rule that *was* loading correctly, `kube-prometheus-stack-kube-apiserver-slos`). The
  three homelab-authored `PrometheusRule` files only had `prometheus: kube-prometheus`
  and `role: alert-rules` -- labels that looked plausible (and matched each other) but
  never matched the actual selector. Confirmed via the live API: 0 of these 3 files'
  rule groups appeared in `/api/v1/rules` before the fix, all 4 appeared immediately
  after adding the missing label (recording rules + SLO alerts + hardware-temp alerts +
  the new control-plane alerts from REL-012).
- **Impact:** this means `SLOAvailabilityFastBurn`/`SLOAvailabilitySlowBurn`,
  `ProxmoxHostHighTemp`, and `RpiHighTemp` have never fired even once, no matter what
  happened to availability or hardware temperatures since these were written --
  directly relevant to REL-012 (the etcd crash-looping went unnoticed "despite Blackbox/
  Prometheus already monitoring most services," but the SLO alerts meant to catch
  exactly that kind of availability drop were dead on arrival the whole time).
- **Fix:** added `release: kube-prometheus-stack` to all three files' `PrometheusRule`
  labels. Verified live, not just via `kubectl apply` succeeding: queried
  `/api/v1/rules` directly before and after, confirmed all 4 rule groups present with
  no `lastError` on any rule.
- **Lesson:** a `PrometheusRule` object existing in the cluster with no errors from
  `kubectl apply` is not evidence it's actually being evaluated -- the operator's
  `ruleSelector`/`ruleNamespaceSelector` match is a separate, silent gate. Check
  `/api/v1/rules` (or the Prometheus UI's Status > Rules page) directly to confirm any
  new alerting rule is actually live, every time.
- **A second, bigger gap found checking how these got deployed at all:** `kubernetes/apps/*`
  gets auto-discovered by the `homelab-apps` ApplicationSet
  (`kubernetes/system/argocd/apps-applicationset.yaml`), but `kubernetes/system/*` does
  **not** — each subdirectory needs its own manually-created Application (the existing,
  documented pattern for `vault-manifests`/`velero-manifests`). `kubernetes/system/monitoring/`
  had no such Application at all. Every raw manifest in that directory (the 4
  PrometheusRules, pve-exporter's Deployment, 3 ExternalSecrets, the Grafana
  IngressRoute, 5 NetworkPolicies, 2 dashboard ConfigMaps) was live in the cluster only
  because someone `kubectl apply`'d it manually at some point — git had zero ability to
  reproduce any of it. Confirmed this wasn't theoretical: `loki-dashboard`
  (a ConfigMap already committed to git) didn't exist live at all, real drift that had
  already happened silently. Added `kubernetes/system/monitoring/manifests-application.yml`
  (same pattern as `vault-manifests`) covering every raw manifest in the directory.
  Verified safe before enabling `prune`/`selfHeal`: diffed every live resource against
  its git source first (NetworkPolicies were byte-identical, ExternalSecret diffs were
  just API-server-defaulted fields, pve-exporter's image matched) — only then applied
  with automation on, and confirmed `loki-dashboard` got created and the namespace
  stayed healthy.
- **This pattern (system/* subdirectories silently missing their own Application) is
  worth auditing more broadly** — not done here, scope was just monitoring/, but every
  other `kubernetes/system/*` directory should be checked the same way before assuming
  "it's in git" means "git can rebuild it."

---

### REL-015 — Discord alerting silently broken: Prometheus Operator can't use `webhook_url_file` · **RESOLVED** (2026-06-24 stopgap, durable fix landed 2026-07-05 via REL-042)

Found while rotating a leaked Discord webhook (separate incident, user-initiated).
Updating the webhook in Vault and forcing an `ExternalSecret`/config-reloader refresh
had zero effect on actual delivery — every test alert failed with Discord's own
`404 Unknown Webhook`, even with a brand new, freshly-created, independently-verified-
working webhook (confirmed via a direct `curl` straight to Discord, bypassing
Alertmanager entirely: `204` success).

- **Root cause:** the rendered Alertmanager config Alertmanager actually loads
  (`alertmanager-kube-prometheus-stack-alertmanager-generated`, the secret the
  Prometheus Operator produces by merging the Helm-rendered base config with any
  `AlertmanagerConfig` CRDs) had a **literal, hardcoded `webhook_url`** baked in —
  not the `webhook_url_file` reference that's actually in git and in the Helm-rendered
  base secret. That generated secret was **24 days old and had never been
  regenerated**, despite the base config correctly changing to `webhook_url_file` at
  some point in that window. The Operator's own logs (`kube-prometheus-stack-operator`)
  showed why, recurring every few minutes since at least 16:46 that day — well before
  any of today's webhook rotation work: `sync "monitoring/kube-prometheus-stack-
  alertmanager" failed: provision alertmanager configuration: failed to initialize
  from secret: no discord webhook URL provided`. The Operator validates
  `webhook_url_file` references in **raw, Helm-injected** Alertmanager config by trying
  to read the file from **its own pod**, which never has that secret mounted (only the
  Alertmanager pod does, via `spec.secrets`) — so this specific pattern can structurally
  never succeed when used inside a raw `alertmanager.config:` block. It's a known
  limitation/mismatch between the raw-config passthrough path and the
  `AlertmanagerConfig` CRD path (which validates secret references via a direct
  `SecretKeySelector` + Secret API lookup instead, and would actually work) — not
  something that broke on its own.
- **Made acutely worse, self-inflicted:** while debugging, deleted the stale
  `-generated` secret to try to force a clean regeneration. The Operator's sync was
  *already* permanently failing for the reason above, so it never recreated anything —
  Alertmanager was left with **no config secret at all** for several minutes (the
  running pod kept its last-loaded in-memory config, but a restart at that point would
  have failed to even start). Restored immediately by manually creating the secret with
  a corrected literal `webhook_url`. Verified via the pod's own logs ("Completed loading
  of configuration file") and a clean test-alert delivery (zero errors logged, vs. the
  explicit 404 on every previous attempt).
- **Current state:** Discord delivery confirmed working again via the manual literal-
  value secret. This is **not durable** — it lives only in the live cluster, not git,
  and would be silently lost if anything ever forces a full clean resync of this secret
  (same failure mode that caused this in the first place).
- **Proper fix — done 2026-07-05, see REL-042:** migrated the Discord receiver and its
  full routing tree (`severity = critical`, the `ProxmoxHostHighTemp`/`RpiHighTemp`
  special-case route, the inhibit rule) to a self-contained `AlertmanagerConfig` CRD.
  That work also surfaced and fixed a second, independent bug blocking it
  (`monitoring-manifests`'s tracking glob was itself missing the two files needed to
  ever apply this fix, so it had silently been a no-op for 8+ days even after being
  written) — see REL-042 for the full writeup. Verified end-to-end via a real test
  alert with `alertmanager_notifications_total{integration="discord"}` incrementing,
  0 failures.
- **Lesson:** the same one as REL-014, reinforced — a Secret/config object existing
  with no errors from `kubectl apply` (or even a `config-reloader` "Reload triggered"
  log line) is not evidence the *content* is correct or that the producing controller
  is healthy. Check the actual producing controller's own logs for sync/reconcile
  errors before trusting that a generated artifact reflects current source config.

---

### REL-016 — `mini` froze solid during an Ollama test, needed a manual power-cycle · **PARTIAL** (2026-06-24)

Self-inflicted, while investigating a `paperless-gpt` quality problem (see WRK-005 follow-
up below). Ran a single test inference against `gemma2:27b` (~18GB, CPU-only since
WRK-004 moved Ollama off the iGPU) to evaluate it as a replacement model. The request
took **17+ minutes** before failing with no output, and within that window the entire
physical host (`mini`) became unreachable: SSH timed out at the banner-exchange stage
(not just slow — the TCP handshake completed but `sshd` never got far enough to respond)
across *every* LXC tried, not just the one running Ollama, and `kubectl` failed with
`no route to host` against the k3s control plane (also virtualized on the same physical
box). Matches the host-freeze failure mode already documented from a prior USB I/O
contention incident (see `docs/OPERATIONS.md`) — confirmed by the user, who'd seen this
exact pattern before tied to disk load. Required a manual power-cycle; no remote
recovery path existed.

- **Root cause, best assessment:** `ct-srv-ai-01` had `cores = 8` (of the host's 16
  logical threads) with **no `cpulimit`** — Proxmox does not isolate CPU between LXCs
  by default, so a CPU-bound inference job could legitimately claim 100% of all 8
  assigned cores indefinitely. The 17-minute runtime for what should be a short
  generation task (a few dozen tokens) points at the *disk* side specifically, though:
  loading an 18GB model file from `rpool`, which REL-005/REL-012 already established is
  under sustained contention at 82%+ utilization, is consistent with the same disk-
  latency cascade already implicated in etcd's crash-looping. CPU and disk contention on
  this single shared host are most likely the same underlying problem wearing two
  different hats, not two separate bugs.
- **Recovery, after the power-cycle:** found that most LXCs (`ct-mgmt-pbs-01`,
  `ct-srv-docker-01`, `ct-srv-ai-01`, `ct-dmz-proxy-01` — which fronts *all* external
  traffic including both Minecraft servers — and `ct-dmz-games-01` itself) had
  `onboot: 0` and did not restart automatically; only `ct-srv-nfs-01`,
  `ct-srv-media-acq-01`, and `ct-srv-jellyfin-01` came back on their own. Every one of
  these had to be found and started manually (`pct start`) one at a time, including
  diagnosing that Cobblemon's *game* port was reachable while its *reverse proxy* LXC
  was still down — two different LXCs, two different fixes, found by testing each port
  independently rather than assuming "the game server" is a single thing to check.
- **Fixed:**
  - `ct-srv-ai-01` reduced from `cores = 8` to `cores = 6`, plus `pct set 201 -cpulimit
    6` applied manually — confirmed via the provider's own schema
    (`terraform providers schema -json`) that bpg/proxmox 0.100.0's container `cpu{}`
    block has **no `limit` attribute at all** (only `architecture`/`cores`/`units`),
    so the cores reduction is the only half of this expressible in Terraform.
  - `onboot=1` set manually on all five LXCs that lacked it. **Also a provider gap, not
    just an oversight on my part**: added `start_on_boot = true` to the Terraform
    resources first, and confirmed live, twice, that `atlantis plan` reports
    "No changes" even though the real `onboot` value was still `0` on the host —
    bpg/proxmox 0.100.0 doesn't read this attribute back from the API into Terraform
    state, so anything declared here silently never takes effect. Reverted that
    Terraform change rather than leave a fix in git that looks real but does nothing;
    documented the gap inline instead (`lxc.tf`, next to each affected resource).
- **Not fixed:** the underlying disk contention (REL-005/REL-012) that's the most
  likely actual trigger. The CPU cap and onboot fixes reduce blast radius and
  recovery time for a recurrence; they don't prevent one. Also not fixed: no
  alerting exists for "host is about to freeze" — REL-012's new `KubeAPIServerDown`
  alert would have caught this episode's *symptom* (the control plane being
  unreachable) if Alertmanager itself weren't on the same affected host and
  potentially unable to deliver during the exact window it would matter most.
- **Lesson:** before running any CPU- or disk-heavy one-off command (loading a new,
  large model; a bulk reindex; anything reading double-digit GB from disk) against
  shared homelab hardware with no resource isolation, check size/impact first — "let's
  just test this" is not a small action on a single-host setup where everything shares
  the same CPU and the same already-contended disk.

---

### REL-017 — `mc-server-2` (the original Minecraft server) had no DNAT rule at all · **RESOLVED** (2026-06-24)

Found while recovering from REL-016: the user reported `mc-server-2` (port 25565)
unreachable, and a direct TCP connect test confirmed it — repeatable, including from
*before* the host froze, ruling out the freeze as the cause.

- **Root cause:** queried the live MikroTik router's NAT table directly via its own
  REST API (`GET /rest/ip/firewall/nat`, using the `terraform` user's credentials
  already in `terraform.tfvars`) rather than guess from Terraform files alone — only
  Cobblemon's `dst-nat` rule (port 25566) existed. **There was no NAT rule for port
  25565 at all**, on the live router or in git. The matching forward-chain ALLOW rule
  (`fwd_wan_minecraft`) existed and always had — but an ALLOW rule only lets traffic
  *through* the firewall once it's already addressed to the internal proxy; without a
  `dst-nat` rule to actually rewrite the destination from the public IP in the first
  place, WAN traffic to port 25565 had nowhere to go. Confirmed both NPM (the reverse
  proxy) and the backend (`ct-dmz-games-01`) were listening and reachable internally
  the whole time via `nc -zv` from the proxy itself — the break was purely the missing
  NAT rule, nothing downstream.
- **Fix:** added `routeros_ip_firewall_nat.dstnat_minecraft`, mirroring the existing
  Cobblemon rule exactly. Verified end-to-end after apply, not just "port open": a real
  Minecraft server-list-ping handshake against the public IP returned the server's
  actual MOTD and version.
- **Unrelated drift surfaced in the same plan:** `routeros_snmp_community.monitoring`
  showed pending changes (clearing `authentication_password`/`encryption_password` to
  null) that had nothing to do with this fix. Checked before approving: the community
  is plain SNMPv2c (a community string, `read_access = true`, no version/security-level
  config), so those fields are vestigial for this resource — safe to let Terraform
  correct back to the declared, secretless config.
- **Lesson:** when a forward-chain filter rule for a port already exists, don't assume
  the matching NAT rule does too — they're independent, and on this router's history
  (see GIT-007/GIT-009) it's already been established more than once that NAT rules can
  go undeclared in Terraform, or simply never get created in the first place, while
  filter rules quietly mask the gap by looking like "the firewall already allows this."
  Query the live router's NAT table directly rather than inferring connectivity from
  the filter rules alone.

---

### REL-018 — `kubernetes/system/*.yml` had zero ArgoCD tracking; a live security regression hid in the gap · **RESOLVED** (2026-06-24, #124)

Found while removing `paperless-ai`'s IngressRoute (WRK-005 follow-up): `kubectl apply
-f` updated the existing resources in `kubernetes/system/apps-ingressroute.yml` but did
not prune the one I'd deleted from the file — it stayed live until I deleted it by hand.

- **Root cause:** `kubernetes/apps/*` is auto-discovered by the `homelab-apps`
  ApplicationSet, but `kubernetes/system/*` was never wired to anything — every
  IngressRoute (most production ingress for the whole homelab) and PodDisruptionBudget
  defined directly under `kubernetes/system/` was live only because someone (me, earlier
  sessions) had applied it manually at some point. A full cluster rebuild from git alone
  would never have created any of it, and nothing was ever pruning resources removed
  from these files.
- **Live security regression found in the process:** `kubernetes/system/infrastructure/
  external.yml` (tracked by the `infrastructure` Application, `selfHeal: true`)
  contained a *second*, less-restrictive `traefik-dashboard` IngressRoute — same name,
  same namespace as the correct one in `other-ingressroute.yml`, but missing the
  `PathPrefix(`/api`) || PathPrefix(`/dashboard`)` restriction. With nothing tracking
  `other-ingressroute.yml`, `infrastructure`'s selfHeal was periodically overwriting the
  correct, path-restricted definition with this unrestricted one — confirmed live by
  checking the resource's `match` field twice within minutes and seeing it flip. A
  third, differently-named, unused duplicate (`traefik-dashboard-websecure` in
  `kubernetes/system/traefik/dashboard-route.yml`) was pure leftover risk and deleted.
- **Fix:** added `kubernetes/system/manifests-application.yml`, a new ArgoCD
  Application (`system-manifests`, `prune: true`, `selfHeal: true`) tracking
  `apps-ingressroute.yml`, `other-ingressroute.yml`, and `pod-disruption-budgets.yml`.
  Removed the duplicate, unrestricted `traefik-dashboard` block from `external.yml` and
  the unused third copy entirely — the path-restricted version is now the only one,
  exclusively owned by `system-manifests`.
- **Lesson:** "is this file under `kubernetes/apps/`" is not the same question as "is
  this file tracked by ArgoCD" — the second one needs to be checked explicitly for
  anything under `kubernetes/system/`, since the ApplicationSet pattern doesn't reach
  there at all.

---

### REL-019 — `rpool` hit hard ENOSPC, paused all three k3s VMs; root cause was a backup job circularly backing itself up · **RESOLVED** (2026-06-25)

Surfaced while testing the `readOnlyRootFilesystem` rollout (SEC-012 follow-up, see
below): a routine `kubectl create job --from=cronjob/renovate` test, running
concurrently with an already-scheduled Velero backup, tipped `rpool` (the single 472GB
SSD shared by every VM/LXC on `mini` — already flagged at 82%+ contention in REL-005/
REL-012) over its last few GB of headroom. `kubectl` started failing with `no route to
host`; the games LXC's Minecraft server lagged badly (same host, same starved disk) and
the user noticed before I'd finished diagnosing it.

- **Immediate symptom:** `qm status` showed `io-error` for all three k3s VMs
  (`vm-srv-k3s-11/12/13`) — QEMU's block layer correctly paused every vCPU on ENOSPC
  rather than crash or corrupt data, but this meant the *entire* k3s cluster (API
  server, etcd, every pod) was simultaneously down with no remote recovery path other
  than freeing pool space and issuing `qm resume` (found via raw QMP socket commands —
  `qm resume` itself failed with "No space left on device" because even Proxmox's own
  task-log writes to `/var/log/pve/tasks` go through the same full pool).
- **Root cause, in order of how much each one mattered:**
  1. **Garage's `garage-data` PVC (10Gi requested, 115GB+ actually used — `nfs-client`
     enforces no quota at all) lives on `rpool`.** Per `CLAUDE.local.md` the 2TB USB
     archive pool is explicitly meant as "the backup/Garage target," but Garage's real
     data has been on the scarce fast SSD the whole time.
  2. **The `daily-backup` Velero Schedule (`includedNamespaces: "*"`,
     `defaultVolumesToFsBackup: true`, `ttl: 720h` = 30 days) was backing up Garage's
     own `data`/`meta` volumes via kopia *into Garage's own S3 backend* every night** —
     a circular write, accumulating for a month before any chunk expired. This was
     always going to eventually fill the pool; 2026-06-25 03:00 UTC was just the day the
     accumulated backups crossed the line. Confirmed via `kubectl get podvolumebackups
     -n velero`: the in-progress `daily-backup-20260625030032-ttntq` PodVolumeBackup was
     backing up pod `garage-76dbb5dc5b-48qtb`'s `data` volume, 120 minutes in.
  3. **No alert existed for ZFS pool capacity at all**, and the one exporter that could
     have provided the metric (`pve-exporter`) had been failing **401 Unauthorized**
     since the day it was deployed — its `pve-exporter-config` Secret had shipped with
     a literal plaintext placeholder, `token_value: REPLACE_WITH_TOKEN_VALUE`, committed
     directly to git and never actually completed. Zero Proxmox host metrics (disk,
     CPU, anything) had ever reached Prometheus.
- **Recovery (in order attempted, several dead ends kept on record deliberately):**
  - Deleted two already-obsolete VM snapshots (10.5GB) and pruned Docker images on the
    Docker LXC (1GB) — bought a few minutes, immediately reconsumed by the in-progress
    backup once `qm resume` brought the VMs back.
  - `kubectl scale deployment velero --replicas=0` did **not** stop the bleed — ArgoCD's
    `selfHeal` silently reverted it within its reconcile cycle (the same "git is the
    only place a fix sticks" lesson from REL-018, again). The actual writer was a
    `PodVolumeBackup` being executed directly by the `node-agent` DaemonSet pod via an
    embedded kopia subprocess — independent of the Velero Deployment's replica count and
    still running via the kubelet even while the API server itself was unreachable.
  - Stopped the NFS LXC (`ct-srv-nfs-01`, vmid 220) directly via `lxc-stop -n 220 -k`
    (bypassing `pct stop`, which itself failed with "No space left on device" trying to
    write its own task log) — this cut off the write *destination* and was the only
    action that actually halted the growth.
  - Deleted the in-progress `Backup` CR (`kubectl delete backup.velero.io
    daily-backup-20260625030032`) and patched `Schedule daily-backup` to
    `paused: true`.
  - Freed real headroom by deleting `gemma2:27b` (15GB — the exact model that caused
    REL-016's host freeze, no longer used) and `gemma4:26b` (17GB, same risk profile,
    never used in production) and `qwen2.5-coder:7b` (4.7GB, already deprecated in
    WRK-005) from the AI LXC's Ollama cache — all three freely re-pullable,
    `minicpm-v` (the one model actually in production use) untouched. `zpool list`
    didn't reflect the free space until an explicit `sync` — a stale read had me
    convinced deletions weren't working for several minutes before realizing it was
    just an unflushed txg.
  - `pveum` itself then hung indefinitely on `cfs-lock 'file-user_cfg'` — pmxcfs's own
    SQLite-backed config store had hit "database or disk is full" mid-transaction
    during the crisis and was stuck. `systemctl restart pve-cluster` cleared it (does
    not affect running VMs/LXCs).
  - Resumed all three VMs, restarted the NFS LXC, confirmed stable at 35GB+ free and
    host load back to 1.04 (from 27.8 at the peak).
- **Fixed, permanently:**
  - `kubernetes/apps/garage/garage.yml`: added
    `backup.velero.io/backup-volumes-excludes: data,meta` to the Garage pod template —
    Velero will no longer attempt to back up Garage's own backing store at all. Also
    corrected the `garage-data` PVC's declared size from the misleading `10Gi` to
    `150Gi` to reflect real usage (still unenforced by `nfs-client`, but no longer
    actively lying).
  - `kubernetes/system/velero/schedule.yml`: `daily-backup` committed to git as
    `paused: true` for now — re-enable once the exclusion fix above has run clean at
    least once.
  - `kubernetes/system/monitoring/external-secret.yml`: replaced the plaintext
    placeholder Secret in `pve-exporter.yml` with a proper `ExternalSecret` (Vault-
    backed, matching the existing pattern used by `grafana-admin-secret` etc.),
    regenerated the `prometheus@pve` API token (the old value had never been captured
    anywhere retrievable), and verified live: the `proxmox-pve` Prometheus target is
    now `up` and `pve_disk_usage_bytes`/`pve_disk_size_bytes` are flowing.
  - `kubernetes/system/monitoring/storage-capacity-alerts.yml` (new): two alerts,
    `ProxmoxStorageCapacityHigh` (>85% for 10m, warning) and
    `ProxmoxStorageCapacityCritical` (>93% for 5m, critical), on
    `pve_disk_usage_bytes / pve_disk_size_bytes` per storage. Verified live via
    `/api/v1/rules` — `ProxmoxStorageCapacityHigh` is correctly `pending` for
    `storage/pve-mgmt-01/local-zfs` at the post-cleanup ~88% usage.
- **Found but not fixed (separate, pre-existing gaps):**
  - `daily-offsite` (`kubernetes/system/velero/offsite-schedule.yml`) exists in git but
    was never actually applied/live — a second, smaller GitOps-coverage gap on top of
    REL-018, not yet investigated further.
  - `node_exporter` is not installed on the bare Proxmox host (`mini`) at all — only
    inside the k3s VMs via DaemonSet. This means `ProxmoxHostHighTemp`
    (`hardware-temp-alerts.yml`, written assuming `node_hwmon_temp_celsius{group=
    "pve_hosts"}` exists) has been silently dead since it was written; confirmed zero
    series returned for that metric. Needs its own Ansible-managed install (the host
    isn't currently in any existing inventory group) — out of scope for this incident's
    fix, tracked here so it doesn't get silently re-lost.
  - The bigger structural question — should Garage's bulk S3 data move off `rpool`
    entirely onto the archive pool, matching `CLAUDE.local.md`'s stated intent — is
    *not* done. The exclusion fix above stops the bleeding (no more circular backup
    growth) but Garage's 115GB+ still lives on the scarce fast SSD. A live migration of
    a real S3 backend (used by Velero as its only backup target) needs its own careful,
    backed-up, verified pass, not something to rush as part of incident recovery.
- **Lesson:** a backup system that includes its own backup target in what it backs up,
  with no exclusion and a multi-week retention, has an unbounded growth bug baked into
  its design — it doesn't matter how much headroom exists on day one, only when it runs
  out. Also: ZFS `zpool list`'s "FREE" column can lag actual writes by a full
  transaction group; `sync` before trusting it during an active space crisis.

---

### REL-020 — Radarr's database hit a transient NFS I/O error on restart; surfaced a live, un-migrated SQLite-on-NFS risk · **RESOLVED** (2026-06-25 incident; underlying risk closed 2026-07-06)

Found while testing `readOnlyRootFilesystem` on the jellyfin/usenet media stack (SEC-012):
restarting Radarr's pod (to apply the patch) made it fail to start with `Database file:
/config/radarr.db is corrupt... disk I/O error`. Kubernetes still reported the pod as
`1/1 Running` throughout — no liveness probe is configured for this Deployment, so a
.NET process hung at "Press enter to exit... waiting for user intervention" counts as
healthy. Radarr was silently down until this was caught.

- **Root cause:** `radarr-config`'s PVC uses the `nfs-client` storage class — the exact
  class already documented elsewhere in this repo (`docs/k3s-architecture.md`) as unsafe
  for embedded SQLite databases, due to NFS's locking/WAL model. This whole media-
  acquisition stack predates GitOps tracking and was missed by the original
  SQLite-on-NFS migration audit (`[[project_sqlite_nfs_risk]]`, RESOLVED 2026-06-23 for
  8 *other* apps). `sonarr-config`, `bazarr-config`, and `sabnzbd-config` are on the
  same storage class and share the same exposure, even though only Radarr happened to
  hit it this time.
- **Recovery:** backed up the live `radarr.db`/`-wal`/`-shm` files first, then ran
  `sqlite3 radarr.db 'PRAGMA integrity_check;'` directly against the NFS-mounted path on
  the host — came back `ok`. This was a transient NFS I/O glitch during SQLite's startup
  migration check, not actual bit-level corruption. `PRAGMA wal_checkpoint(TRUNCATE)`
  cleared the pending WAL cleanly (`0|0|0`), and Radarr started normally afterward with
  zero data loss. A 2-day-old internal Radarr backup
  (`Backups/scheduled/radarr_backup_*.zip`) existed as a fallback but wasn't needed.
  sonarr's and bazarr's databases were also checked (`integrity_check: ok`) as a
  precaution.
- **Resolved, re-checked 2026-07-06:** the WRK-006 cutover this finding was waiting on
  has completed — confirmed live that `kubectl get deploy/pvc -n apps` returns nothing
  for `sonarr`/`radarr`/`bazarr`/`sabnzbd` at all, and `ct-srv-media-acq-01`'s
  `/opt/media-acq` (where these apps' config/SQLite databases now live) is on the LXC's
  own local ZFS subvolume (`rpool/data/subvol-202-disk-0`), not NFS. The underlying
  SQLite-on-NFS risk this finding describes no longer applies — not because the PVCs
  were migrated to `local-path` as originally proposed, but because the apps aren't on
  any Kubernetes-provisioned storage at all anymore. This closes out cleanly because
  the dependency (WRK-006) resolved as *correct-by-design* (see WRK-006's own updated
  entry), not because of a pending removal that might still slip.
- **Also missing:** none of these five Deployments have a liveness probe, which is why
  Radarr's failure was invisible to Kubernetes. Not added here (would need per-app
  endpoint/auth research, out of scope for this incident) but worth doing regardless of
  whether the storage migration happens.
- **Lesson:** a `1/1 Running` Deployment with no liveness probe proves the container
  process didn't exit — it proves nothing about whether the application inside is
  actually working. Always check the *current* pod's logs and a real functional
  request, not just `kubectl get pods`, especially right after triggering a restart.

---

### REL-021 — Authelia's readOnlyRootFilesystem fix passed a live test, then crash-looped in production hours later · **PARTIAL** (2026-06-25)

Caught because of a real outage report: `home.woitzik.dev` (and presumably every other
Authelia-protected route) returned Service Unavailable. Two of three Authelia replicas
were in `CrashLoopBackOff` with 35+ restarts over roughly 2.5 hours.

- **What happened:** the `readOnlyRootFilesystem` change for Authelia (part of the
  SEC-012 pass, merged in #133) was tested live before committing -- patched the
  Deployment, watched it fail once with a generic `fatal: Errors occurred performing
  startup checks`, retried, watched it succeed (`Startup complete`, `/api/health`
  returned `{"status":"OK"}`) -- and was committed and merged on that basis. Hours
  later, in production, the exact same config started crash-looping persistently. The
  fatal error message gives no further detail in either case (Authelia logs nothing
  more specific before the generic "Errors occurred performing startup checks" line),
  so the underlying cause is still unknown.
- **What this means for the "test live, then commit" discipline:** a single successful
  retry after one failure is not sufficient evidence that a fix works, if the failure
  mode is intermittent rather than deterministic. The original incident (the blind
  capabilities/runAsNonRoot rollout) was about not testing live at all; this is the
  opposite failure -- testing live, getting a result that looked like a pass, and
  trusting it without enough repetition or a long enough observation window. Both are
  the same root mistake: declaring success from too little evidence.
- **Fix:** reverted `readOnlyRootFilesystem` on Authelia's main container (kept it on
  the `wait-for-vault-secret` initContainer, which was never implicated). Verified the
  Service's endpoints only ever routed to the two healthy replicas throughout --
  `home.woitzik.dev` was very likely never actually down end-to-end, just degraded to
  whatever capacity the surviving replicas could handle, which is still bad (no
  redundancy, and a full Authelia outage was one bad rollout away).
- **Found in the same response:** a second, unrelated SEC-012 regression on
  `homepage` -- its entrypoint auto-creates `/app/config/docker.yaml` if missing, and
  that directory turned out to be a plain writable directory (not itself a ConfigMap
  mount, only the individual files inside it are subPath-mounted), so
  readOnlyRootFilesystem broke that specific write with `EROFS`. Fixed by adding an
  empty `docker.yaml` to the ConfigMap, mounted the same way as the others -- Docker
  integration isn't actually used here.
- **Not fixed:** the actual root cause of Authelia's intermittent failure under
  readOnlyRootFilesystem. Candidates not yet ruled out: a periodic internal task
  (TOTP/WebAuthn cleanup, session GC, certificate reload) that needs to write
  somewhere not covered by the `/tmp` mount added for the notifier; a race between the
  three replicas' chown attempts on the shared `secrets`/`users-db` mounts (read-only
  regardless, but the *attempt* itself might behave differently under load); or
  something unrelated to the filesystem entirely that just happened to correlate.
  Needs a debug-level Authelia log capture during an actual failure (not a retry after
  one) before attempting this again -- not done here, given the priority was restoring
  service, not root-causing while it was down.
- **Lesson:** for a service that gates access to *every other* Authelia-protected app
  in this homelab, the bar for "tested enough" before merging a security-hardening
  change should be higher than one pass after one retry. Worth revisiting with a
  proper soak test (leave the live patch running, unwatched, for an hour+) before
  re-attempting readOnlyRootFilesystem on Authelia.

---

### REL-022 — Third SEC-012 readOnlyRootFilesystem regression: open-webui static assets · **RESOLVED** (2026-06-25)

Found in a full-homelab log sweep the user explicitly requested after REL-021
("look at everything... you can't tell me there is not more to do?"). Same root
cause class as Authelia and homepage in REL-021: open-webui rewrites several of
its own static branding assets (`splash.png`, `splash-dark.png`, favicon
variants, `loader.js`, `logo.png`, `custom.css`, `apple-touch-icon.png`,
`user.png`) under `/app/backend/open_webui/static/` at startup, and
`readOnlyRootFilesystem` (merged earlier in the SEC-012 pass) broke every one of
those writes with `EROFS` on every boot.

- **Why not the same fix as homepage:** homepage's regression was one missing
  config file, safe to add via a ConfigMap subPath. open-webui's static
  directory ships real, required assets (`fonts/`, `swagger-ui/`, multiple
  icons) that a bare `emptyDir` overlay would silently wipe, breaking the whole
  UI (404s on every asset) -- a much worse outcome than the cosmetic EROFS
  errors being fixed.
- **Fix:** added an init container that `cp -a`s the image's own static
  directory into an `emptyDir`, then mounts that `emptyDir` over the same path
  in the main container. Preserves every existing file while making the
  directory writable. Verified post-merge: no more EROFS errors in logs, pod
  rollout clean.
- **Process note confirming the REL-021 lesson:** attempted to live-test this
  fix the same way as before (`kubectl apply` then observe) -- ArgoCD's
  `selfHeal` reverted the live patch back to the old (broken) spec within
  seconds, before there was any chance to observe results, because the change
  wasn't in git yet. Skipped the live-test step entirely this time and went
  straight to commit-merge-verify, since the fix mirrored the already-proven
  homepage pattern. Live-testing against a `selfHeal: true` Application without
  committing first doesn't just risk false confidence (REL-021's lesson) -- it
  can fail to test anything at all.

---

### REL-023 — Garage backup chunk corruption + nfs-provisioner-root backup gap · **PARTIAL** (2026-06-25)

Found in the same full-homelab sweep: Garage logging `Unable to decode entry of
object` / `Error in worker object lifecycle worker` roughly every minute.
Investigated given Garage had just undergone a live data migration (REL-019) --
needed to rule out the migration itself having lost data.

- **What's actually wrong:** `garage block list-errors` showed 8 blocks with
  persistent resync failures ("no node returned a valid block" -- this is a
  single-node Garage instance, so "no node" means the block is genuinely absent
  locally). `garage block info <hash>` traced every one of them to `kopia`
  (Velero's filesystem-backup tool) backup chunks for exactly two volumes: the
  `nfs-subdir-external-provisioner` pod's own PV (the literal root of the NFS
  export, not just bookkeeping) and two PVs in the `apps` namespace. No live
  application data is missing -- this is backup-repository corruption, not a
  live data loss.
- **Likely cause:** the timing point to the disk-full crisis window (REL-019,
  `rpool` at 0% free) -- writes into Garage's old `rpool`-backed data directory
  during that window could have been silently truncated before the migration
  moved everything to the archive pool. Not confirmed beyond strong
  correlation; Garage's block store doesn't keep enough history to prove it
  definitively.
- **Verification taken:** ran an ad-hoc full `apps` + `nfs-provisioner`
  namespace backup (`defaultVolumesToFsBackup: true`) to get a clean,
  post-migration restore point. Result: `PartiallyFailed`, 1078/1078 items
  attempted. Two of three failures were harmless collateral from an open-webui
  pod rollout happening concurrently (`Pod not found` -- expected, not a bug).
  The third reproduced live: `nfs-subdir-external-provisioner-root`'s volume
  backup was canceled (`data path backup canceled: PVB is canceled`) -- same
  volume implicated in the historical corruption, now failing again on a fresh
  attempt.
- **Not fixed:** root cause of why `nfs-provisioner-root`'s volume backup gets
  canceled is still unknown -- not a "pod not found" collateral issue like the
  other two, a real, repeatable failure on a volume that (per the migrated
  state, see the SQLite-on-NFS migration memory) may still hold live data for
  whatever's left on the `nfs-client` storage class. Needs investigation into
  Velero node-agent resource limits/timeouts or file-lock contention with the
  provisioner's own active writes before this volume's backups can be trusted.
- **Recommendation, not yet actioned:** once the cause of the cancellation is
  understood, consider whether `nfs-provisioner-root` even needs fs-backup at
  all (if everything still on `nfs-client` is non-critical/replaceable) versus
  fixing the cancellation. Decide before relying on it for a restore.

---

### REL-013 — Redundant monitoring: two systems probing the same ~20 endpoints, too aggressively · **RESOLVED** (2026-06-24)

Found while investigating unusually high DNS query volume reported live (AdGuard:
1.86M queries/week, `vm-srv-k3s-11` alone responsible for 69% of all queries network-
wide). Two independent monitoring systems were both doing HTTP(S) uptime checks against
nearly the same set of `*.woitzik.dev` hostnames:

- **Uptime Kuma**: 23 active monitors, every one checking every **60 seconds** (some
  matching the exact same targets Prometheus's blackbox-exporter also checks: Authelia,
  Vaultwarden, Home Assistant, Nextcloud, ArgoCD, etc).
- **Prometheus blackbox-exporter**: 9 HTTP targets, scraped at Prometheus's global
  default interval (confirmed live: `30s`), no per-job override.

Each check does its own DNS resolution; with `search home.lan` configured on the k3s
nodes' resolv.conf (confirmed via `resolvectl status` on `vm-srv-k3s-11`), most lookups
get queried twice (once plain, once with `.home.lan` appended) — visible directly in
AdGuard's top-domains list, where `auth.woitzik.dev` and `auth.woitzik.dev.home.lan`
both show near-identical counts. Possibly a contributing factor to REL-012's etcd disk-
I/O starvation, given this all runs on the same contended node.

- **Fix:** Bumped Uptime Kuma's 23 monitors from 60s to 300s interval (direct SQLite
  update — Kuma has no bulk-edit UI for this — backed up `kuma.db` first, restarted the
  pod since the scheduler caches intervals in memory). Added explicit
  `scrape_interval: 60s` to both blackbox-exporter Prometheus jobs (doubling their
  interval from the 30s global default).
- **Not fixed / out of scope for this pass:** the underlying `search home.lan` doubling
  itself, and the deeper redundancy of running two separate uptime-checking systems
  against overlapping targets at all — consolidating onto one would be a bigger,
  separate decision (Uptime Kuma's simple status page vs. Prometheus/Alertmanager's
  richer alerting are both genuinely useful, not obviously redundant to remove either).
- **Effort:** Small for what was done; the `search home.lan` / dual-system question is
  a separate, larger decision.

---

### REL-006 — No VM-level Proxmox snapshots for k3s nodes · **HIGH**

`pvesh get /nodes/pve-mgmt-01/qemu/211/snapshot` returns only `current` — no named
pre-change snapshots. The CLAUDE.local.md guardrail #1 requires a snapshot before any
change affecting running state.

- **Impact:** No VM-level rollback point if a k3s upgrade or OS change goes wrong.
  Recovery falls back to PBS restore (when PBS is running) or k3s rebuild from scratch.
- **Fix:** Take a named Proxmox snapshot before any infra change:
  `qm snapshot 211 pre-<change> --description "..."`. Add to runbook.
- **Effort:** Trivial (command takes <30 seconds per VM).

---

### REL-007 — Vault sealed on startup; auto-unseal works but ExternalSecrets fail during the gap · **RESOLVED (mitigated)**

`vault-0` seals on restart; `vault-unseal` polls and auto-unseals, so this self-resolves,
but during the seal window ExternalSecrets can't sync and any pod whose Secret doesn't
exist yet (cold start / disaster-recovery rebuild, not a routine pod restart — an existing
Secret object is untouched by Vault sealing) would otherwise crash-loop on a missing
`secretKeyRef`.

ArgoCD sync waves (the originally proposed fix) turned out not to actually address this:
waves only order resources within an ArgoCD-initiated *sync*, not the pod restart order
after a node/cluster reboot, which is what kubelet drives independently of ArgoCD.

Fixed 2026-06-23 with the two changes that actually help regardless of how the restart
happens:

1. `vault-unseal` poll interval: 30s → 5s — shrinks the seal window 6x.
2. Added a `wait-for-vault-secret` initContainer to Authelia and `postgres-paperless`
   (the two apps explicitly observed crash-looping) that blocks on the expected secret
   files existing, with the secret volume marked `optional: true` so the pod can actually
   be scheduled and run the wait loop even if the Secret doesn't exist at all yet — instead
   of CrashLoopBackoff's exponential backoff, it just polls every 2s and starts the instant
   the secret appears.

**Not fixed, flagged as a new finding:** Vault's own raft storage (`data-vault-0` PVC) is
*also* on `nfs-client`. Raft uses BoltDB underneath, which has similar (though less
severe — single-writer, not WAL/shared-mmap) file-locking requirements to the SQLite
issue in GIT-006. No corruption observed so far, but given Vault is the secrets root for
half the cluster, migrating it deserves its own careful, dedicated pass (like the GIT-007
state rebuild) rather than being rushed alongside this fix.

---

### REL-008 — uptime-kuma uses local-path storage (single-node, non-NFS) · **LOW, accepted risk** (re-checked 2026-07-06)

`uptime-kuma-data` PVC uses `local-path` StorageClass rather than `nfs-client`. This means
the data is stored on the node's local disk (`/var/lib/rancher/k3s/storage`), which is the
k3s-11 VM disk.

- **Re-checked, original suggested fix was wrong:** the original recommendation
  ("migrate to `nfs-client`, consistent with all other PVCs") would actively reintroduce
  the exact corruption risk GIT-006 spent real effort eliminating — confirmed live that
  uptime-kuma is SQLite-backed (`/app/data/kuma.db`), and SQLite-on-NFS is the documented
  anti-pattern this repo has spent multiple incidents removing everywhere else. `local-path`
  is the *correct* storage class for a SQLite workload; the real gap is only reschedule
  risk, not the storage class choice itself.
- **Reschedule risk is smaller than stated:** confirmed live that `uptime-kuma-data` (and
  its `tmp` volume) already gets captured every night by the existing `daily-backup`
  Velero schedule (`kubectl get podvolumebackups.velero.io -n velero -l
  velero.io/backup-name=<latest>` shows both, `Completed`, kopia). A reschedule to a
  different node would still cause a live gap until someone restores from that backup —
  not zero-risk — but it is not the unrecoverable full data loss the original wording
  implied.
- **Fix:** None needed structurally — `local-path` is right for this workload, and
  Velero already covers it. Accepted as a known, backed-up, single-node-scheduling
  tradeoff (`k3s-11` remains the sole viable node for anything stateful+local-path per
  the deliberate single-server design in `docs/k3s-architecture.md`).
- **Effort:** None.

---

### REL-009 — Vault's raft storage was on `nfs-client` · **RESOLVED** (2026-06-24)

Same risk class as GIT-006: Vault's raft storage uses BoltDB underneath (`raft.db`,
`vault.db`), which has the same file-locking assumptions that broke Garage's SQLite
metadata DB on NFS. No corruption had occurred yet, but Vault is the root of every
secret in the cluster — worth fixing proactively rather than waiting for an incident.

- **Fix:** Took a `vault operator raft snapshot save` backup and a Proxmox VM snapshot
  of `vm-srv-k3s-11` first. Paused the ArgoCD application-controller (this Application
  has `selfHeal: true` and would otherwise fight a live StatefulSet/PVC swap).
  Scaled Vault to 0, deleted the StatefulSet with `--cascade=orphan` (keeps the PVC
  alive), copied `data-vault-0`'s contents to a new `local-path` PVC via a temporary
  pod (two hops, since the final PVC needs the exact same name `data-vault-0` for the
  Helm chart's `volumeClaimTemplate` to bind to it rather than auto-creating a new
  nfs-client one) — verified byte-identical via `md5sum` on `raft.db`/`vault.db` at
  every hop before deleting anything. Old PVC's underlying PV has `Retain` reclaim
  policy, so the original NFS data also survives independently as a second safety net.
  Updated `kubernetes/system/vault/application.yml`'s Helm value
  (`server.dataStorage.storageClass: local-path`) and re-applied (per GIT-003, this
  Application's own spec needs a manual `kubectl apply`, same as GIT-010). Vault came
  back up, auto-unsealed via the existing sidecar, `HA Mode: active`, all cluster-wide
  ExternalSecrets stayed healthy throughout.
- **Effort:** Small once the GIT-009/GIT-010 PVC-swap and Application-apply patterns
  were already established earlier the same day — done.

---

### REL-010 — `postgres-authelia` (CNPG) was on `nfs-client` · **RESOLVED** (2026-06-24)

Lower-urgency cousin of GIT-006/REL-009 (Postgres has real locking, unlike SQLite/BoltDB,
so this was flagged as LOW rather than HIGH) — migrated anyway while the pattern was
fresh from REL-009, since Authelia's auth database is still high-blast-radius if anything
ever did go wrong.

- **Fix:** Took a `pg_dump` logical backup first (in addition to the Proxmox snapshot
  already taken for REL-009 on the same node). Used CNPG's **declarative hibernation**
  feature (`cnpg.io/hibernation=on` annotation) instead of manually deleting the
  StatefulSet — this is CNPG's own documented mechanism for exactly this scenario:
  cleanly stops the instance while leaving the PVC intact. Same two-hop PVC copy as
  REL-009 (old name -> temp local-path PVC -> delete old -> final PVC named
  `postgres-authelia-1` on local-path -> copy from temp -> delete temp), verified by
  comparing total logical byte counts (`stat -c '%s'` summed across all files, not
  `du -sh` — NFS under-reports real usage via `du`, a red herring that cost some time
  mid-migration) plus `md5sum` on `PG_VERSION` and `global/pg_control`.
  - **The real complication:** a manually-created PVC isn't enough for CNPG to recognize
    it as belonging to the cluster on resume — it needs the `cnpg.io/cluster`,
    `cnpg.io/instanceName`, `cnpg.io/pvcRole=PG_DATA` labels, the `cnpg.io/nodeSerial`
    and `cnpg.io/pvcStatus=ready` annotations, **and an `ownerReference` to the Cluster**.
    Missing the ownerReference specifically caused the cluster to declare itself
    `Cluster is unrecoverable and needs manual intervention` / "restore from a recent
    backup" — a scary-sounding terminal state that was actually just one missing field,
    not real data loss (confirmed the PVC's data was always intact throughout; adding
    the ownerReference and re-cycling hibernation resolved it immediately).
  - Real data on disk (~10.4GB logical) was already larger than the declared `8Gi`
    request (NFS doesn't enforce capacity the way local-path/block storage might) —
    bumped the declared size to `12Gi` for headroom and accuracy.
- **Verified:** `totp_configurations`/`encryption` row counts unchanged post-migration,
  Authelia reconnected and served traffic normally (confirmed via a live
  `https://auth.woitzik.dev/api/health` 200 and real OIDC consent-flow traffic in logs).
- **Note:** the live `Cluster` spec briefly drifted back to `nfs-client` via ArgoCD
  self-heal before this fix was committed — cosmetic only (CNPG doesn't recreate an
  already-bound PVC just because the declared storageClass changed), but a reminder that
  GIT-003's manual-apply gap applies to *any* live edit of an ArgoCD-tracked resource,
  not just the Application objects themselves.
- **Effort:** Small in mechanics, but the CNPG label/ownerReference requirements were
  undocumented and took real investigation to find.

---

## 3. GitOps Quality

### GIT-001 — Terraform state backend requires live Garage (in-cluster) · **HIGH**

Both Terraform stacks use `backend "s3"` pointing to `http://garage.apps.svc.cluster.local:3900`.
This means `terraform init` and `atlantis plan/apply` require the cluster and Garage pod to
be healthy. If Garage is down (cluster restart, PVC issue), Terraform operations block
entirely.

- **Impact:** During a cluster recovery scenario (exactly when you'd want to run Terraform),
  the Terraform backend is also unavailable.
- **Fix:** Set up a Cloudflare R2 or external S3-compatible backend as a fallback, or
  document a manual state unlock procedure. At minimum, keep a local copy of the state file.
- **Effort:** Medium.

---

### GIT-002 — k3s-12 and k3s-13 labels say "worker" in Terraform but they're control-plane nodes · **LOW**

`vm.tf` tags k3s-12 and k3s-13 as `["k3s", "worker", "kubernetes"]` — but they were
migrated to control-plane + etcd nodes in June 2026. The Terraform tags are stale.

- **Fix:** Update tags to `["k3s", "control-plane", "etcd", "kubernetes"]` in `vm.tf`.
- **Effort:** Trivial.

---

### GIT-003 — ArgoCD ApplicationSet covers only `kubernetes/apps/*`; system components are manual · **HIGH** (severity raised 2026-06-24)

The `homelab-apps` ApplicationSet auto-deploys everything under `kubernetes/apps/*` but
`kubernetes/system/*` requires manual `kubectl apply`. A merge to main of a system
component does not deploy it — it must be applied manually or via a separate ArgoCD
Application per component. Critically, this applies to the *Application objects
themselves*, not just the resources they manage: editing an existing
`kubernetes/system/<name>/application.yml` (e.g. fixing a `directory.include` glob) has
**zero effect** until someone manually re-applies that exact file — the Application's own
`spec` is not watched for drift from git at all.

Some system components (cert-manager, metallb, traefik, etc.) have their own ArgoCD
`Application` manifests inside `kubernetes/system/<name>/application.yml`, but others
do not (postgres cluster, redis, argocd itself, infrastructure resources).

- **Impact:** Drift risk for system components. A change pushed to git may not deploy
  automatically, and there is no alert when the live state diverges.
- **Confirmed real impact, not just theoretical (2026-06-24):** GIT-010's fix (correcting
  `postgres-cluster-application.yml`'s glob) merged cleanly via PR but never took live
  effect — and neither had REL-011's `ScheduledBackup` fix from earlier the same day,
  for the exact same reason. Both required a manual `kubectl apply` discovered only by
  noticing `status.history` hadn't recorded a sync since 2026-06-18.
- **Fix:** Document explicitly which system components are ArgoCD-managed vs. manual-apply.
  Add a runbook step to check `kubectl get applications -n argocd` against the list after
  every system PR merge. Longer-term: bring `kubernetes/system/*` Application objects
  themselves under a parent "app of apps" Application so edits to *them* also auto-sync —
  this is the actual fix, not just a checklist step.
- **Effort:** Small for the documentation/runbook step (done implicitly via this entry);
  larger for the real app-of-apps fix (not done).

---

### GIT-004 — Proxmox provider version uses pessimistic constraint `~> 0.69` · **RESOLVED** (stale, re-checked 2026-07-06)

`terraform/stacks/proxmox/providers.tf` originally used `version = "~> 0.69"` for the
`bpg/proxmox` provider, well behind the latest available at the time.

- **Re-checked 2026-07-06:** already resolved — this constraint has been progressively
  bumped by Renovate across several past PRs (#182, #235, and others) and now reads
  `~> 0.111`. Checked the Terraform Registry directly: `0.111.1` is the actual latest
  release across the entire provider, and `.terraform.lock.hcl` already resolves to
  exactly that version. There is nothing to bump — this finding was simply never
  marked resolved after Renovate did the work.
- **Effort:** None needed — already done.

---

### GIT-005 — Offsite Velero BackupStorageLocation has placeholder URL · **DEFERRED (deliberate, 2026-06-24)**

`kubernetes/system/velero/r2-backuplocation.yml` contains:

```yaml
s3Url: https://ACCOUNT_ID.r2.cloudflarestorage.com
```

This is a literal placeholder committed to git. The Secret (`velero-r2-credentials`) does
not yet exist in the cluster.

- **Investigated 2026-06-24:** evaluated Cloudflare R2 (zero egress fees, but no
  platform-level hard spending cap — only lifecycle rules and usage monitoring as soft
  safety nets) vs Backblaze B2 (a true hard `$0` cap that refuses writes once the free
  tier is exceeded, but charges egress on restore). Given the explicit requirement to
  never incur cost under any circumstance, decided to **skip offsite cloud backup for
  now** and rely on existing local Proxmox/PBS backups only, rather than accept R2's
  soft-cap risk or B2's restore-time egress cost.
- **Fix (if revisited):** Either credential set works once a clear cost tolerance is
  set; B2 is the safer default if the bar is "must never bill," R2 if occasional
  restore-testing cost is acceptable in exchange for zero ongoing egress risk.
- **Effort:** Small once a provider + credentials are decided.

---

### GIT-010 — `postgres-cluster` Application's directory glob never matched its ExternalSecret · **RESOLVED** (2026-06-24)

Found while verifying REL-011's `ScheduledBackup` was actually GitOps-tracked.
`postgres-cluster-application.yml`'s `directory.include` was
`'{cluster,cnpg-backup-secret,scheduled-backup}.yml'` — but the real file in that
directory is `external-secret.yml`, not `cnpg-backup-secret.yml`. `kubectl get
application postgres-cluster -o jsonpath='{.status.resources}'` confirmed only the
`Cluster` was tracked; the `cnpg-garage-backup` ExternalSecret has been running this
whole time only because it was applied manually once and never touched since — a
silent, permanent drift risk (anyone editing it in Git would see no effect at all).

- **Fix:** Corrected the glob to `'{cluster,external-secret,scheduled-backup}.yml'`.
  Verified the live `cnpg-garage-backup` ExternalSecret's spec already matches the
  repo's `external-secret.yml` exactly, so adopting it into GitOps is a clean no-op.
- **Bigger problem found applying the fix:** merging the PR alone did nothing — this
  `Application` object lives under `kubernetes/system/*`, which (per GIT-003) isn't
  covered by any ApplicationSet or parent Application. Its own spec only ever gets
  updated by a manual `kubectl apply` of `postgres-cluster-application.yml` itself;
  nothing watches it for drift from git. `kubectl get application postgres-cluster -o
  jsonpath='{.spec.source.directory.include}'` still showed the broken glob *after*
  merge, confirmed via `status.history` that the Application hadn't actually
  re-synced since 2026-06-18. This means **REL-011's `ScheduledBackup` never actually
  deployed either**, despite that PR merging cleanly — same root cause, just not
  caught until now. Ran the manual `kubectl apply` to push the corrected spec live;
  all three resources (`Cluster`, `ExternalSecret`, `ScheduledBackup`) now show
  `Synced` under `status.resources`.
- **Effort:** Trivial — done, but flags GIT-003 as more urgent than "documentation
  only": at least one real fix (REL-011) silently failed to deploy because of it.

---

### GIT-011 — Two more silent failures discovered applying WRK-006's new LXC · **RESOLVED** (2026-06-24)

Both surfaced as real `atlantis apply` errors (not silent this time) while provisioning
WRK-006's `ct_srv_media_acq_01`:

1. **The Atlantis Terraform API token isn't `root@pam`** — Proxmox only allows
   configuring `device_passthrough` on container *creation* for `root@pam`. The AI LXC's
   existing `device_passthrough` blocks (GPU passthrough) only work because that
   container was created manually as root and imported into state afterward — they
   never actually exercised the CREATE path via this token. Removed the block from the
   new LXC's create path; will add it back manually via root SSH once the bare container
   exists, then reconcile state the same way.
2. **`usb-templates`' Proxmox storage *definition* was missing from
   `/etc/pve/storage.cfg`**, so `pvesm status` and the API didn't know it existed —
   initially misdiagnosed this as the physical USB disk being unplugged, which was
   wrong; the disk (`sdb`, 460GB) was physically connected and already mounted at
   `/mnt/pve/usb-templates` the whole time, template file intact. Just the storage
   *registration* was gone. Re-registered with `pvesm add dir usb-templates --path
   /mnt/pve/usb-templates --content vztmpl,iso,backup` — no data lost, no workaround
   needed once correctly diagnosed.

- **Effort:** Small, but both would have silently blocked any future LXC creation
  (including the still-planned Jellyfin GPU-passthrough LXC) until hit by trial and
  error.

---

### GIT-009 — Two live NAT masquerade rules were never declared in Terraform · **RESOLVED** (2026-06-24)

Confirmed live via the RouterOS REST API (`GET /rest/ip/firewall/nat`) that both rules
exist and carry real traffic, but neither had a Terraform resource:

- `*5` — outbound internet masquerade ("NAT: Outbound Internet Access"). Also turned up a
  second, unrelated problem while investigating: this rule's `out-interface-list` field
  points at interface-list id `*2000010`, which no longer exists (`GET
  /rest/interface/list` only returns the 4 RouterOS builtin lists). The rule still
  masquerades correctly because RouterOS keeps matching on the cached internal reference,
  but the management API can no longer resolve or display it by name — a dangling
  reference from some earlier, undocumented change.
- `*8` — masquerade for MGMT (VLAN 10) → SRV (VLAN 20) return traffic.

- **Fix:** Added `routeros_ip_firewall_nat.srcnat_masquerade_wan` and
  `.srcnat_masquerade_mgmt_to_srv` in `terraform/stacks/network/nat_portforward.tf`, with
  `import` blocks in `imports.tf` targeting live ids `*5`/`*8`. For `*5`, declared
  `out_interface = "ether1"` (the WAN interface used everywhere else in this codebase)
  instead of trying to recreate the dangling interface-list — verified via `terraform
  plan` (run locally, read-only, against the real backend/router) that this produces a
  clean in-place update on `*5` (swap `out_interface_list = "*2000010"` for
  `out_interface = "ether1"`) and a zero-diff import on `*8`.
- **Note:** `terraform plan` also surfaced an unrelated, pre-existing drift on
  `routeros_snmp_community.monitoring` (write-only password fields always show as a diff
  since RouterOS can't return them for comparison) — not caused by this change, left alone.
- **Blast radius:** Requires an `atlantis apply` to take effect. `*8` is a no-op apply. `*5`
  briefly recreates the WAN masquerade match criteria in place (RouterOS updates the rule's
  fields, not a delete+recreate) — should not cause a connectivity gap, but is the one part
  of this PR actually touching live, traffic-carrying WAN NAT, so apply it during a low-risk
  window.
- **Effort:** Small — code written and validated; needs `atlantis apply` to land.

---

## 4. IaC Quality

### IAC-001 — No resource limits on most Kubernetes workloads · **RESOLVED**

Most of the originally-flagged apps (bazarr, gitea, home-assistant, jellyseerr, mealie,
nzbhydra2, open-webui, radarr, sabnzbd, sonarr) picked up limits incidentally during other
work this session (image pinning, NFS migrations). Swept the remaining 16 containers
across 13 manifests on 2026-06-23 and added `resources.requests`/`limits` to all of them:
atlantis, authelia, cloudflared, garage, headscale, homepage, keel, postgres-paperless,
redis-paperless, paperless-addons (gotenberg + tika), uptime-kuma, vaultwarden, the
cloudflare-ddns CronJob, pve-exporter, and redis-authelia. Verified zero remaining gaps
via a script over every Deployment/StatefulSet/DaemonSet/CronJob in `kubernetes/`.

Also found and removed `kubernetes/system/redis/application.yml` — a stale duplicate of
`redis.yml` still referencing the long-removed Longhorn StorageClass; harmless (the live
StatefulSet already matched the current file) but dead, confusing code.

- **Fix still pending:** flip Kyverno's `require-resource-limits` policy from `Audit` to
  `Enforce` now that the gap is closed (see SEC-006).

---

### IAC-002 — MikroTik firewall hardening apply pending Atlantis · **RESOLVED** (superseded, 2026-07-06)

Per `docs/OPERATIONS.md`: `terraform/stacks/network/imports.tf` is committed and validates
clean, but has never been applied via Atlantis because Atlantis itself is k3s-hosted (and
Garage, which backs the TF state, is also k3s-hosted). Any Atlantis apply requires the
cluster to be fully healthy first.

- **Fix (via unrelated later work, confirmed still valid on doc cleanup pass):** ADR-012
  (REL-036) moved Atlantis off k3s onto its own dedicated LXC, decoupling it from cluster
  health entirely. Since then the network stack has been applied cleanly and repeatedly
  (GIT-007 state rebuild, GIT-008/GIT-009/REL-047/REL-048, the 2026-07-05 firewall/DNS
  work) — the original "apply is stuck" condition no longer exists in any form.
- **Note found while cleaning this up:** this same ID, "IAC-002", was later reused in the
  summary table for a *different*, unrelated finding (the Minecraft WAN-port-forward
  removal / playit.gg DNS cutover) — that entry has been renumbered to **IAC-004** to
  remove the collision. See IAC-004 for that finding.

---

### IAC-003 — No Ansible role for k3s VM provisioning (cloud-init only) · **LOW**

k3s VMs are provisioned via Terraform with cloud-init. There is no Ansible role for
post-provisioning k3s configuration (aside from the `k3s-cluster/` sub-repo). If a k3s
VM needs to be rebuilt, the process is partially documented in `docs/k3s-architecture.md`
but is not fully automated.

- **Fix:** Document the exact rebuild procedure in `docs/disaster-recovery.md` (which
  doesn't exist yet — see DOC-001).
- **Effort:** Documentation.

---

### IAC-005 — Cleanup batch: dead `minio` container, stale merged branches, 2 stale doc claims · **RESOLVED** (2026-07-06)

Found during the `docs/STATUS.md` re-assessment pass (2026-07-06): a handful of small,
independent, low-risk items worth batching into one cleanup PR rather than opening
several trivial PRs.

- **Dead `minio` container removed from `ct-srv-docker-01`.** Created 2026-04-03,
  `/data` was 535 KB (effectively empty), zero traffic, zero Ansible/git
  representation — a leftover from before Garage replaced it (matches the "legacy —
  superseded by Garage" note already in `docs/secrets-inventory.md` since
  2026-06-19). Snapshotted the LXC (`pct snapshot 200 pre-minio-removal-2026-07-06`)
  before touching anything, then `docker rm -f minio` + deleted `/opt/minio`.
  Confirmed no systemd unit/compose file/restart trigger would ever recreate it, and
  the host's other containers (promtail, node_exporter, watchtower) were unaffected.
- **Branch hygiene cleanup, real count smaller than first estimated.** `git branch -a
  --no-merged` initially showed ~74 stale-looking branches, but that ancestry check is
  unreliable across squash-merges (a squashed commit is never a literal ancestor of the
  original branch's commits, so every squash-merged branch shows as "not merged" even
  when fully redundant). A `git fetch --prune` first cleaned up the majority — those
  were stale local remote-tracking refs for branches GitHub had already deleted via
  `--delete-branch`, not real branches. Of the 7 genuinely remaining remote branches,
  checked each one's actual PR merge state via `gh pr list` (the reliable signal,
  not ancestry/cherry-pick matching) plus a zero-unique-commits check as a fallback:
  **4 confirmed merged, deleted** (`chore/rotate-cloudflare-dns-token` #283,
  `feat/rel029-nextcloud-app-upgrade` #259/#260, `fix/authelia-hardening-and-searxng`
  #229, `fix/paperless-gpt-prompts` — no PR record but zero commits ahead of `main`).
  **3 deliberately left alone**: `renovate/ghcr.io-renovatebot-renovate-43.x` backs the
  currently-open PR #302; `renovate/nextcloud-34.x` (#212) and `renovate/postgres-18.x`
  (#214) are genuinely closed-not-merged — their intent was fulfilled via REL-028/029's
  separate manual migration PRs instead, but deleting an abandoned branch with real
  unique commits is a judgment call, not an automatic cleanup, so left for the account
  owner to confirm. Also cleaned up 8 local-only branches on this checkout (same
  verification method, zero effect on the remote repo).
- **`docs/runbooks/pending-major-upgrades.md`** corrected — it opened with "nothing
  here has been executed" despite 3 of its 4 tracked migrations (REL-028/029/030)
  having completed and been verified weeks earlier. Only REL-027 (Vault unseal-CLI)
  is still genuinely pending.
- **REL-015 marked RESOLVED**, cross-referenced to REL-042 (the actual durable fix,
  landed and verified 2026-07-05) — it had sat as PARTIAL since 2026-06-24 despite
  being closed out.
- **GIT-004 marked RESOLVED** — the Proxmox provider constraint (`~> 0.111`) already
  tracks the latest available release (`0.111.1`, confirmed against the Terraform
  Registry directly); Renovate had already done the work across several past PRs,
  the finding just was never marked closed.
- **Lesson, same theme as the rest of this session's docs-drift findings:** every
  one of these was "already fixed" or "safe to fix trivially" — the actual work was
  small. What made them findings at all was that nobody had gone back to confirm
  status after the underlying fact changed. A periodic "is this finding still
  accurate" pass is worth as much as finding new bugs.

---

## 5. Documentation

### DOC-001 — No DISASTER-RECOVERY.md · **RESOLVED** (2026-06-23)

`CLAUDE.local.md` requires "A top-level DISASTER-RECOVERY.md describes full-rebuild +
per-service restore, kept current."

Added `/DISASTER-RECOVERY.md` at repo root covering all 6 required tiers (network,
Proxmox, k3s bootstrap, ArgoCD bootstrap, Vault init/unseal/ESO, Velero restore) as
runnable command sequences, plus a per-service restore table covering every node-pinned
`local-path` app, CNPG/Authelia's bootstrap-secret gotcha, Nextcloud's non-CNPG Postgres,
Jellyfin's unbacked `media` PVC, the NFS LXC's concurrency constraint, and the Cobblemon
LXC (outside k8s/ArgoCD/Velero's scope entirely). Also corrected two prerequisite stale
docs this depended on: `docs/k3s-architecture.md` (still described the reverted 3-way
HA topology) and `README.md`'s stack table (same stale claim).

- **Not yet tested end-to-end** — this is a written, reasoned-through procedure, not a
  drilled one. Treat as best-effort until an actual (or staged) recovery exercises it;
  update it with whatever doesn't match reality when that happens.
- **New gap surfaced while writing this:** CNPG's `postgres-authelia` cluster has
  continuous WAL archiving configured (barman → Garage S3) but no `ScheduledBackup`
  resource — so there's no base backup to restore from via barman alone. Logged as
  `REL-011` — **RESOLVED**, see below.

---

### DOC-002 — ROADMAP.md is partially in German · **RESOLVED** (re-checked 2026-07-06)

The ROADMAP contained a mix of German and English text ("Abgeschlossen", "offen",
"benötigt"). For a public portfolio repo read by potential employers, this inconsistency
reduces readability.

- **Re-checked:** already fully English — no German words found (`grep -niE
  "abgeschlossen|offen|benötigt|geplant|erledigt"` returns nothing, no umlauts/ß either).
  This must have been translated at some point (matches a commit message on this repo:
  "Translate ROADMAP.md to English (public repository)") but the finding was never
  marked resolved. Stale entry, closing it out.
- **Effort:** None needed — already done.

---

### DOC-003 — compute-nodes.md says RPi runs HAProxy/Traefik as ingress gateway — this is stale · **RESOLVED**

`docs/compute-nodes.md` lists "HAProxy / Traefik — Ingress gateway routing TCP traffic to
K3s backend" as an RPi service. The actual ingress path is MetalLB → Traefik running
inside k3s. The RPis run AdGuard + Unbound only. The table was not updated after the
ingress migration.

- **Fix:** Remove the HAProxy/Traefik line from the RPi services table; update to reflect
  AdGuard + Unbound + Keepalived only.
- **Effort:** Trivial.
- **Resolution:** Reworded the RPi section ("HA Ingress Layer" / "Gateway Strategy") to
  drop the ingress claim and added a note that MetalLB + in-cluster Traefik own k3s
  ingress; RPis only run AdGuard + Unbound + Keepalived.

---

### DOC-004 — Missing ADRs for several architectural decisions · **RESOLVED**

Decisions that were not recorded as ADRs:

- Velero + Kopia for PVC backup (the `defaultVolumesToFsBackup` fix is a significant decision)
- CloudNativePG for Authelia Postgres (migration from bare StatefulSet)
- Network policies: default-deny pattern and the rollout incident
- Vault auto-unseal design

Existing ADRs: Unbound (ADR-001), Cloudflare Tunnel (ADR-002), Garage as TF backend
(ADR-003), 3-2-1 backup (ADR-004), NFS over Longhorn (ADR-005).

Added `docs/decisions/ADR-006-cloudnativepg-authelia.md`,
`ADR-007-velero-kopia-pvc-backup.md`, `ADR-008-networkpolicy-default-deny.md`, and
`ADR-009-vault-auto-unseal.md`, each grounded in the actual git history and commit
messages behind the decision (CNPG migration commits, the 2026-06-19 Velero
`defaultVolumesToFsBackup` incident, the NetworkPolicy rollout breaking Velero→Garage and
Homepage→Uptime Kuma, and the `vault-unseal` polling-sidecar design from REL-007).

---

### DOC-005 — `docker/crafty/` and `docker/npmplus/` described services that don't exist live; real fix was Ansible, not new reference copies · **RESOLVED** (2026-07-06, corrected same day)

Found during a portfolio-quality pass ("what would a reviewer flag") prompted by SEC-015.
Compared the two files under `docker/` against what's actually running on the two DMZ
LXCs (`ct-dmz-proxy-01`, `ct-dmz-games-01`) via `docker inspect`/`docker ps` — **neither
committed compose file matched live reality**: `docker/crafty/docker-compose.yaml`
described Crafty Controller managing Minecraft (live: two plain `itzg/minecraft-server`
containers, Crafty isn't running at all); `docker/npmplus/docker-compose.yml` described
the `zoeyvid/npmplus` fork (live: plain `jc21/nginx-proxy-manager` + a separate CrowdSec
container).

**First-pass fix was wrong, corrected within the same session**: initially assumed
`docker/` was the actual (if stale) deployment mechanism and replaced the two dead files
with fresh reference copies pulled off the live hosts (`docker/minecraft/`, `docker/npm/`,
plus newly-added `docker/watchtower/`, `docker/promtail/`, `docker/node-exporter/` for
three more containers found running with no repo representation at all). **This was
based on an incomplete check** — `ansible/roles/` already has real, working,
templated roles for every one of these: `minecraft`, `nginx_proxy_manager`,
`crowdsec_bouncer`, `watchtower`, and `monitoring_agent` (the last one deploys the
docker-based `node_exporter` + `promtail` pair specifically for the `nodes` group —
`rpi_nodes`/`dmz_proxies`/`dmz_games` — as a distinct pattern from `node_exporter_native`,
which every other host group uses instead). Confirmed via `ansible/site.yml`: these
roles are actually applied to `dmz_proxies`/`dmz_games` on every playbook run. Adding a
second, static, un-templated copy under `docker/` created exactly the "which one is
real" confusion this whole pass was trying to eliminate — removed `docker/` entirely
once this was clear; the Ansible roles are the single real source now.

**A genuine, previously-unknown drift was found while verifying this**:
`ansible/roles/minecraft/tasks/main.yml` hardcoded the `minecraft-2` service's volume as
`./data-2:/data` and only pre-created `/opt/minecraft/data`/`data-cobblemon` — but the
*live* container (`mc-server-2`) is actually mounted at `/opt/minecraft/data-3`
(confirmed via `docker inspect`), one of four world directories on the host
(`data`, `data-2`, `data-3`, `data-cobblemon`, plus an `alte_welten` manual-archive
folder) — someone had manually reconfigured which world is live at some point without
ever updating the Ansible role to match. Had the playbook been re-run against this host,
it would have redeployed a docker-compose pointing back at the stale `data-2` world
(831MB, last modified 2026-06-20) instead of the actually-active `data-3`
(283MB, last modified 2026-06-28) — a real, live risk of silently reverting the running
Minecraft world on the next routine Ansible run. Fixed the role to reference `data-3`;
verified safe via `ansible-playbook site.yml --limit dmz_games --check --diff` showing
the compose-file task as `ok` (no diff) against the live host, not `changed`.

- **Lesson (the corrected one): before assuming something is "not IaC-managed," check
  `ansible/roles/` and `site.yml` for a matching role FIRST** — don't default to
  "must be manually deployed" just because a stale-looking committed file exists
  elsewhere. And separately: **a role matching live reality today doesn't mean it still
  will after a manual live reconfiguration** — the same "git vs. reality" drift class
  that hit ArgoCD-managed Kubernetes manifests (REL-042/046) applies just as much to
  Ansible-managed Docker Compose hosts.
- **Effort:** Small — done (docker/ removed, Ansible role corrected, verified via
  `--check --diff`, not applied destructively).

---

### DOC-006 — Two conflicting Renovate configs at repo root, one of them dead · **RESOLVED** (2026-07-06)

`renovate.json` and `renovate.json5` both existed at repo root with genuinely different
settings (the `.json` had the `kubernetes` fileMatch and immich/major-update
`packageRules` that SEC-005's fix actually edited and confirmed working; the `.json5`
had `automerge` for minor/patch, `:rebaseStalePrs`, explicit ansible/terraform/kubernetes
manager enables, and a custom `regexManager` for Helm chart tracking).

- **Confirmed dead:** Renovate's config-file discovery order checks `renovate.json`
  before `renovate.json5` in the same directory and uses only the first match — it does
  not merge both. Since `renovate.json` exists, `renovate.json5` has never been read at
  all. Verified this didn't leave a real functional gap: Terraform provider bumps and
  Helm chart `targetRevision` bumps (e.g. the kube-prometheus-stack v61→v87 upgrade)
  have both actually happened via Renovate PRs — covered by Renovate's own built-in
  default managers, not the dead file's explicit settings or its custom regexManager.
- **Fix:** removed `renovate.json5`. No behavior change (it was never active); a
  reviewer no longer has to figure out which of two config files is the real one.
- **Effort:** Small — done.

---

## 6. Useful-Workload Gaps

### WRK-001 — Jellyfin and media stack stuck in ContainerCreating · **RESOLVED** (2026-06-24)

Resolved as part of WRK-007 (Jellyfin moved to dedicated LXC) and WRK-006 (media acquisition
stack moved to VPN-isolated LXC). See those entries for the full resolution details.

---

### WRK-002 — Minecraft/playit.gg not GitOps-managed (backup coverage re-checked, better than assumed) · **LOW** (re-checked 2026-07-06)

CLAUDE.local.md lists Minecraft as a target useful workload ("fully GitOps-managed,
backed up, and documented"). The game server (`ct-dmz-games-01`) is not exposed through
k3s and has no runbook of its own beyond `DISASTER-RECOVERY.md`'s per-service table.

**Re-checked as part of the 2026-07-05 security review**, which had flagged the
playit.gg tunnel agent (installed 2026-07-04 for IAC-004's WAN-port-forward removal) as
having "zero IaC/backup representation" — **that claim was only half right**. The agent
(`/etc/playit/playit.toml`, holding the tunnel's claimed identity/secret — losing it
means re-claiming a new tunnel and a new `*.joinmc.link` hostname, breaking the
`mc.woitzik.dev` CNAME) was installed manually via `apt` (playit's own repo), not
Ansible — that half of the gap is real. But **it is not backup-uncovered**: confirmed
live via `pvesh get /cluster/backup` that the PBS job (`backup-8b6a6f73-c4ce`, `all: 1`,
only VMID 9000 excluded) includes `ct-dmz-games-01`, and confirmed actual nightly
backups exist and succeed (`state: ok`, most recent 2026-07-06 01:07). `playit.toml`
is part of the LXC filesystem, so it's captured every night along with everything else.
`DISASTER-RECOVERY.md` already correctly documents "Restore via Tier 1 (PBS) only" for
this LXC — that path fully restores playit's identity intact.

- **Residual gap, real but narrower than previously stated:** only if the PBS backup
  itself were lost (not just the LXC) would recreating from Terraform + a fresh manual
  `apt install playit` produce a *new* tunnel identity, silently breaking the DNS CNAME
  until someone notices and updates `var.mc_playit_hostname`. This is a secondary,
  low-probability failure mode (PBS itself has its own retention/verification), not the
  "no backup at all" gap originally flagged.
- **Fix, not done:** an Ansible role to install/configure playit idempotently would
  close the from-scratch-rebuild case, but given PBS restore already covers the much
  more likely single-LXC-loss scenario, this is a nice-to-have, not urgent.
- **Effort:** Small for the Ansible role; the underlying backup risk is already low.

---

### WRK-003 — Paperless requires Vault to be unsealed; fails on cluster restart · **RESOLVED**

Specific case of REL-007 — fixed the same way (2026-06-23): `postgres-paperless` now has
a `wait-for-vault-secret` initContainer that blocks until `paperless-secrets` actually
contains `postgres-password`, instead of crash-looping. See REL-007 for the full fix.

---

### WRK-004 — paperless-gpt failing on every document; Ollama iGPU crashing constantly · **RESOLVED** (2026-06-23)

`paperless-gpt` was failing 100% of auto-tagging/OCR jobs with "unexpected EOF" from the
LLM. Root cause: Ollama's AMD iGPU backend (`ct-srv-ai-01`, Ryzen 5825U/Barcelo, gfx90c)
was crashing with `vk::DeviceLostError` ("context is lost") roughly once per inference
call under any concurrent load — 451 crashes logged in a single day. This chip has no
official ROCm support; the live config had drifted to `OLLAMA_IGPU_ENABLE=1` (a Vulkan/
radv fallback path), which is what was actually crashing — not the `HSA_OVERRIDE_GFX_VERSION=9.0.0`
ROCm spoof originally declared in `ansible/roles/ollama/tasks/main.yml` (also never stable
on this chip, abandoned at some earlier point without anyone reverting the Ansible role).

- **Fix:** Switched Ollama to CPU-only (removed both GPU env vars from the systemd
  override). Verified stable under a 6-request concurrent stress test (0 crashes, all
  succeeded) before rolling out via Ansible. Restarted `paperless-gpt`; confirmed a real
  document processed end-to-end (title/tags/correspondent/date all correctly extracted,
  ~5.5 min on CPU vs. near-instant on a working GPU — slower but actually completes).
- **Separately verified, not broken:** Jellyfin's transcoding path uses a different GPU
  block entirely (VAAPI video encode/decode, not Vulkan compute) — confirmed healthy via
  `vainfo` and a real `ffmpeg` hardware encode test on the same chip. The Ollama crash says
  nothing about VAAPI's stability. However, Jellyfin currently has **no GPU passthrough
  configured at all** (separate, pre-existing gap, not something this incident caused) —
  tracked as a follow-up to move Jellyfin to its own GPU-passthrough LXC, same pattern as
  `ct_srv_ai_01`, since Proxmox iGPU passthrough is exclusive and can't be shared between
  the AI LXC and a k3s VM simultaneously.
- **Known fallout:** the document backlog that failed during the crash period was
  retried automatically by paperless-gpt's own retry logic once Ollama stabilized — but
  several documents in Paperless show garbled/hallucinated titles and content from
  earlier broken AI runs (unrelated model, predates this fix). Needs a manual data-quality
  pass, tracked separately.

---

### WRK-005 — Paperless data-quality pass: missing archives (NFS) + upside-down scans · **RESOLVED** (2026-06-24)

Two unrelated, real findings from the WRK-004 follow-up data-quality pass:

**1. 41 of 57 documents had a missing archived PDF.** `download/?original=true` worked
fine (raw scans intact) but `preview/`/`download/` (which serve the post-processing
`archive` copy) 404'd — confirmed the entire `archive/2024/` directory and most of
`archive/2023` etc. didn't exist on disk at all, while the DB still had
`archived_file_name` set. `paperless-media` is on the `nfs-client` StorageClass — same
storage class already implicated in GIT-006's SQLite corruption findings; this is very
likely the same family of NFS reliability issue, just affecting plain files instead of a
locked database this time. No data was actually lost (originals survived) — regenerated
all 41 archives via Paperless's own `python3 manage.py document_archiver -d <id> -f`
(re-derives the archive from the existing original + OCR text, no LLM involved).

**2. The 5 "hallucinated" documents (26, 44, 55, 57, 58) from WRK-004 were never actually
hallucinated — they're scanned upside down (180°).** Confirmed by pulling each original
PDF and reading it directly: all 5 are genuine, perfectly legible German documents (a
sick note, an IHK letter, a reference letter, a tax ID notice, an IHK membership notice)
that just happen to be rotated 180° in the scan. *Both* the broken text-only model
(WRK-004's root cause) *and* the now-working `minicpm-v` vision model produced fluent
nonsense when fed an upside-down page — garbled German-looking anagrams from one,
random Thai script from the other — because neither could actually read the orientation,
not because either model is fundamentally broken.

- **Fix:** `POST /api/documents/bulk_edit/` with `{"method": "rotate", "parameters":
  {"degrees": 180}}` (Paperless's native rotate action) on all 5, then re-tagged for
  OCR. Verified doc 26's rotated original renders right-side-up and fully legible.
- **Lesson for any future "AI hallucinated this" report:** check the source image's
  orientation/quality first — a vision model failing to read upside-down or badly
  skewed text looks identical to a model that's broken, but the fix is completely
  different (rotate the page vs. swap the model).
- **Effort:** Small once root-caused; the root-causing itself was the real work.

**3. `LLM_MODEL` (`qwen2.5-coder:7b`) was systemically broken, not just occasionally
chatty — resolved.** What looked low-frequency in the first pass turned out to be the
steady state: confirmed via a longer log window that it was *routinely* ignoring the
prompt's explicit "title only" and "respond in German" instructions, writing multi-
paragraph English essay summaries instead of titles, and in one case hallucinated a
completely unrelated personal-advice response. Every one of these also failed
correspondent creation (`Ensure this field has no more than 128 characters`), since the
same broken text got reused as the correspondent name. Switched `LLM_MODEL` to
`minicpm-v` (already loaded for vision, same 7.6B size class, zero new resource risk)
— tested clean via a direct Ollama API call before deploying.

**4. Switching models didn't fully fix it — found a deeper design problem.** Minutes
after the model swap, `minicpm-v` silently corrupted a real document: replaced
correspondent "NRW" with a freshly-*created* garbage correspondent literally named
"Yes", and the title with just "The" — applied with zero human review via
`paperless-gpt`'s fully-automatic `AUTO_TAG` pipeline. Reverted the document and
deleted the garbage correspondent manually. **Two different models now producing bad
output that gets auto-applied unreviewed means the auto-apply pipeline itself isn't
safe to run unattended, regardless of which model sits behind it.** Disabled it by
pointing `AUTO_TAG` at a tag name that doesn't exist (so the auto-scan always matches
zero documents) — the manual `paperless-gpt` tag, where a human reviews suggestions
before they're applied, is the only enabled workflow now.

**5. A third, separate AI tool (`paperless-ai`) had the same design flaw plus a live
landmine — removed entirely (user's call).** Found while extending this audit:
`paperless-ai`'s entire config lives in a runtime data volume (a `.env` file + SQLite,
invisible to git — its own form of drift from "if it's not in git it doesn't belong
here"), had `AUTO_TAG`/`AUTO_CORRESPONDENT`/`AUTO_TITLE` all enabled with zero review
(same flaw as #4), and — found directly inside that `.env` — was configured to use
`gemma2:27b`, the exact model that froze the entire host during REL-016 hours earlier.
Currently dormant only because its own setup is incomplete (`"Failed to get own user
ID. Abort scanning"`, a `PAPERLESS_API_URL` vs. `PAPERLESS_URL` naming mismatch) — not
dormant by design, and would have started auto-applying with that model the moment
anyone completed its `/setup` step or an image update fixed the env var bug. Swapped
the model to `minicpm-v` immediately as a precaution regardless of outcome, then asked
the user whether the tool was wanted at all (duplicates `paperless-gpt`'s function,
already broken, config outside IaC). Answer: remove it entirely. Deleted the
Deployment/Service/PVC and the matching `paperless-ai-final` IngressRoute (the only
other reference to it in the repo); confirmed the PVC held nothing but its own
regenerable index/cache data (a ChromaDB vector store + its own SQLite document cache),
no source documents.

- **Lesson, broader than Paperless:** "AI suggests, human approves" and "AI decides,
  no review" look identical in a Deployment's env vars until something goes wrong —
  the risk lives in the *auto-apply* design itself, not in which model is configured.
  Any tool with an unattended write-back path to real data needs that path checked
  explicitly, not just the model quality.

---

### WRK-006 — Media acquisition stack: dedicated VPN-isolated LXC · **RESOLVED** (2026-07-06 — verified correct as designed, not "removed")

SABnzbd had a hand-rolled Mullvad WireGuard kill switch (init container + manual
iptables) but the WireGuard config was a placeholder — fails closed (no leak) but
non-functional, and Sonarr/Radarr/Bazarr/NZBHydra2 had no VPN protection at all despite
making indexer/metadata queries that are arguably more privacy-sensitive than the
download traffic itself.

- **Decision:** move the whole stack to a dedicated LXC using gluetun (purpose-built
  Mullvad client + kill switch) instead of per-app sidecars, plus a standalone Tor SOCKS
  proxy for NZBHydra2's indexer queries specifically (not bulk downloads — Tor's
  bandwidth can't handle that, and doing so would be abusive to the shared network).
  Full reasoning in `docs/decisions/ADR-010-media-acquisition-lxc.md`.
- **Provisioned:** `ct_srv_media_acq_01` (10.0.20.253) exists and is running. Hit two
  more `root@pam`-only Proxmox API restrictions doing this (GIT-011): `usb-templates`'
  storage registration was missing (disk was fine, just unregistered — re-registered),
  and `device_passthrough` can't be configured on container *creation* via Atlantis's
  token (worked around by creating the bare container first, adding `/dev/net/tun`
  passthrough manually via root SSH once it existed, then declaring it in Terraform
  afterward to avoid drift — confirmed via `atlantis plan` showing zero diff).
- **NFS turned out to be a dead end inside this unprivileged container** — confirmed
  live that NFS client mounts fail with EPERM regardless of the `mount=nfs` Proxmox
  feature flag (both NFSv3 and NFSv4), a deeper unprivileged-userns kernel restriction,
  not a network/AppArmor problem (`showmount` RPC queries succeed fine). Fixed with two
  different approaches: the media library is bound in via a native Proxmox LXC mount
  point (it's a local ZFS dataset on the same host anyway, no NFS needed), and per-app
  configs were copied once via `tar | ssh | tar` directly between hosts instead of an
  ongoing NFS mount.
- **Deployed and validated:** `ansible-playbook site.yml --limit media_acq_nodes` ran
  clean — Docker installed, all 7 containers (gluetun, Sonarr, Radarr, Bazarr, SABnzbd,
  NZBHydra2, Tor, Jellyseerr) built and started. Confirmed the kill-switch architecture
  works exactly as intended: gluetun crash-loops on the still-placeholder Mullvad config
  rather than passing traffic unprotected — correct, safe failure mode.
- **Deliberately not done yet:** the old Kubernetes Deployments/PVCs and Traefik
  IngressRoutes are left untouched until the new stack has a real Mullvad config and is
  fully verified — cutting over before that would risk a window with no working
  acquisition stack at all. The config copy done so far is structurally complete but not
  byte-for-byte final (a few SQLite WAL files were locked by the still-running k8s pods
  during the copy) — the real, final sync happens at actual cutover time with the
  source apps stopped.
- **Resolution, re-checked 2026-07-06:** the gluetun/Mullvad half of this decision was
  never completed and is no longer needed. Live-verified via `docker ps` on
  `ct-srv-media-acq-01` that no `gluetun` container exists — the stack settled on a
  simpler final design instead, documented in the live `docker-compose.yml`'s own
  comment block: **SABnzbd connects directly to Eweka over SSL/NNTPS (port 563,
  `ssl=1`/`ssl_verify=2` confirmed live in `sabnzbd.ini`)** — already fully encrypted
  end-to-end to the provider, so a VPN/proxy layer on the download path adds no privacy
  benefit and costs real throughput + risks Eweka flagging the account for
  apparent IP-sharing (a known issue with VPN IPs shared across many subscribers).
  **The Tor SOCKS5 proxy stays** for its original, different purpose: NZBHydra2's
  *indexer search queries* (to NZBGeek/DrunkenSlug/etc. — HTTP requests that are not
  inherently encrypted/IP-hidden the way NNTPS downloads are). Confirmed live in
  `nzbhydra.yml`: `proxyType: SOCKS`, `proxyHost`/`proxyPort` pointing at the Tor
  container (`9150`), configured with no direct-connection fallback — a Tor outage
  blocks indexer queries rather than silently leaking the home IP (fail-closed by
  design). One explicit exception exists: `proxyIgnoreDomains: [nzbfinder.ws]`
  bypasses Tor for that specific indexer. Full rationale captured in
  `docs/decisions/ADR-013-tor-proxy-indexer-queries.md`.
- **Not touched, on purpose:** confirmed the SABnzbd-side kill-switch/VPN concern from
  this finding's original opening was really about the *download* path, which the
  direct-SSL design already addresses without needing gluetun at all — nothing here
  was "removed," the architecture that shipped was simply different (and simpler) than
  ADR-010's original gluetun-for-everything plan, and re-verified as the *correct*
  choice rather than an incomplete one.

### WRK-007 — Jellyfin moved to a dedicated GPU-passthrough LXC · **RESOLVED** (2026-06-24)

The k3s Deployment had no GPU passthrough at all — pure software transcode, despite
CLAUDE.local.md already stating hardware transcode should run on mini's APU.

- **Provisioned** `ct_srv_jellyfin_01` (10.0.20.254) reusing mini's AMD Vega iGPU render
  node (`/dev/dri/renderD128`) already passed through to `ct-srv-ai-01` for ROCm —
  confirmed concurrent access from both LXCs is fine, it's a DRM render node, not an
  exclusive lock. Hit the same `root@pam`-only restriction on container creation as
  WRK-006, this time for **both** `device_passthrough` and `mount_point type bind`
  (the latter hadn't shown up on WRK-006 because that block was added *after* the
  container already existed, never exercising the create path) — same fix: create bare,
  configure manually via root SSH, declare in Terraform afterward to avoid drift.
- **Config migration hit a subtler problem:** `tar | ssh | tar` between the NFS host
  and the new LXC intermittently corrupted mid-stream (`tar: Skipping to next header`)
  even with the source pod fully stopped — not the file-lock issue from WRK-006's NFS
  copy, since stopping the writer didn't fix it reliably. Saving the tar to a local file
  first and checking its byte count against the source (`wc -c` on both ends) before
  extracting caught it immediately when corrupt and confirmed success when clean;
  retrying the same command got a good copy. Root cause not fully pinned down (likely
  an NFS server-side artifact, not file locking) — worth remembering as a verify-before-
  trusting step for any future host-to-host copy in this repo, not just diagnosing after
  the fact.
- **Verified before cutover:** `ffmpeg` reports `h264_vaapi`/`hevc_vaapi`/etc. as
  available, `/dev/dri/renderD128` visible inside the container with the right group,
  migrated config preserved exactly (`jellyfin.db` byte-identical, `StartupWizardCompleted:
  true`, real server name, 0 pending migrations against the restored DB — confirms the
  schema was already current, not silently reset), and `/media` library paths matching
  the old k3s mount 1:1 (same `/media` path inside the container either way).
- **Cutover:** kept the existing Traefik IngressRoute and Authelia middleware
  untouched — only swapped the `jellyfin` Service's backend from a pod selector to a
  manually-pointed external IP, so nothing downstream needed to change.
- **Two more issues found live during cutover, both fixed same-day:**
  - **Shared-PVC blast radius:** the `media` PVC/PV removed from `jellyfin.yml` turned
    out to *also* be referenced by name from `usenet.yml`'s Sonarr/Radarr/Bazarr/SABnzbd
    Deployments (`claimName: media`) — a coupling invisible from jellyfin.yml alone.
    Caught before any actual disruption: the PVC went into `Terminating` but stayed
    `Bound` and those 4 pods stayed `Running` (blocked by `kubernetes.io/pvc-protection`
    until the pods that reference it go away) — a safe-but-temporary window, not a free
    pass. Fixed by recreating the same NFS volume under new names in `usenet.yml` (its
    actual remaining owner) and repointing those 4 Deployments to it; the old PVC/PV
    finished terminating cleanly once nothing referenced them anymore. **Lesson:** before
    deleting any PV/PVC, grep the whole `kubernetes/` tree for its name, not just the
    file that appears to define it — cross-file `claimName` references are easy to miss.
  - **EndpointSlice doesn't work for this use case:** routing the `jellyfin` Service to
    an external IP via a bare `EndpointSlice` looked completely correct via `kubectl`
    (Service + EndpointSlice both existed, endpoint listed right) but Traefik 404'd
    `media.woitzik.dev` regardless. Its own logs gave the real reason directly:
    `subset not found for apps/jellyfin` — Traefik's Kubernetes CRD provider resolves
    Service backends through the legacy `v1/Endpoints` API ("subsets"), not
    `EndpointSlice`, regardless of which one Kubernetes itself prefers. Switched to a
    plain `Endpoints` object; confirmed fixed via both `curl` and Traefik's logs going
    quiet for that ingress.
- Old k8s Deployment/PVCs/PV removed (all `Retain` reclaim policy, so the underlying
  NFS data wasn't touched, just the k8s objects pruned). Final state confirmed end to
  end: `media.woitzik.dev` reachable through Traefik, the 4 still-running k8s media-
  acquisition pods unaffected, Jellyfin container healthy on the LXC.

---

### WRK-009 — Immich: no external access + stuck on v1.109.2 · **RESOLVED** (2026-06-27)

Immich was running `v1.109.2` (PostgreSQL 16 + pgvecto.rs) with no external access path —
reachable only from inside the VPN. Two problems discovered together:

**1. Version gap:** The Immich mobile app had auto-updated to v2.x but the server was still
on v1.109.2. The app showed "your app major version is not compatible with the server." Root
cause: Renovate was deployed but its Kubernetes manager was not configured (SEC-005/2026-06-27
fix), so none of the 93 container images in `kubernetes/` were being tracked. The version
drifted silently over months.

**2. Upgrade path blocked:** Direct jump from v1.109.2 to v2.7.5 fails with
`Invalid upgrade path: 1744910873969-InitialMigration`. Immich v2 switched from TypeORM to
Kysely; the Kysely InitialMigration requires all TypeORM migrations to have run first, which
is only true through v1.x patch releases — a multi-hop intermediate upgrade through every
minor in between would have been required. Since no photos had been uploaded yet (only
account/password existed in the DB), a fresh install was simpler and correct.

**Resolution — fresh install v2.7.5 (2026-06-27, PR #174):**

- Postgres `immich-db` PVC data wiped via busybox pod (confirmed empty before scaling up)
- New postgres image: `tensorchord/pgvecto-rs:pg16` → `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` (VectorChord replaces pgvecto.rs; PG14; no custom `shared_preload_libraries` args)
- Redis replaced by Valkey: `redis:7.4-alpine` → `valkey/valkey:9-alpine`
- Server/ML upgraded: `v1.109.2` → `v2.7.5`
- Port changed: `3001` → `2283`
- Two follow-up readOnlyRootFilesystem fixes needed (REL-024, REL-025)

**External access — Cloudflare Tunnel (2026-06-27, PR #165):**
Immich is the first service exposed externally (family photo backup use case). Decision to
use the existing Cloudflare Tunnel rather than VPN-only or port-forwarding — see
ADR-011 for reasoning. Terraform stack `terraform/stacks/cloudflare/` manages the tunnel
config and DNS record (`photos.woitzik.dev → http://immich-server.apps.svc.cluster.local:2283`).

AdGuard DNS split: `*.woitzik.dev` wildcard returns `10.0.20.200` (Traefik VIP). Since
`photos.woitzik.dev` goes through Cloudflare, not Traefik, added specific A-record rewrites
for Cloudflare's anycast IPs (`172.67.137.91`, `104.21.38.184`) so internal clients also
reach the tunnel rather than hitting a dead Traefik backend.

---

### REL-024 — Valkey RDB persistence fails with readOnlyRootFilesystem · **RESOLVED** (2026-06-28)

Immediately after the Immich v2.7.5 fresh install (WRK-009), photo sync failed with
`MISCONF Valkey is configured to save RDB snapshots, but it's currently unable to persist to
disk`. Valkey's default config enables RDB point-in-time snapshots and AOF, which require
writes to the working directory. With `readOnlyRootFilesystem: true` and no writable `/data`
volume, this trips `stop-writes-on-bgsave-error` and blocks all write commands.

Immich uses Valkey purely as a cache and job queue — persistence adds no value and would
survive a Valkey restart with empty state fine (jobs are re-queued on next media scan).

**Fix (PR #188):** `command: ["valkey-server", "--save", "", "--appendonly", "no"]` —
disables both RDB and AOF, runs fully in-memory. No data loss risk given the workload.

---

### REL-025 — immich-ml model downloads fail with readOnlyRootFilesystem · **RESOLVED** (2026-06-28)

After REL-024 was fixed, Immich ML returned HTTP 500 for all CLIP and face-recognition
requests. Root cause: HuggingFace's xet downloader writes temporary files to
`~/.cache/huggingface` on the root filesystem during model download. With
`readOnlyRootFilesystem: true`, these writes fail with `RuntimeError: Data processing error:
I/O error: Read-only file system (os error 30)`, and the model never loads into memory.

The OCR models (PP-OCRv5) succeeded because they use a different download path (direct HTTP
to modelscope.cn), which writes only to `/cache` (the writable PVC).

**Fix (PR #190):** Added `HF_HOME=/cache/huggingface` and `XDG_CACHE_HOME=/cache/xdg`
environment variables to the `immich-ml` container, redirecting all HuggingFace/XDG cache
writes to the writable `immich-ml-cache` PVC.

Gunicorn logs a non-fatal `Control server error: [Errno 30] Read-only file system` on every
startup — this is a gunicorn hot-reload socket path issue, cosmetic only (workers start and
serve correctly). Not fixed; low priority.

---

### REL-026 — Immich large-file uploads via Cloudflare Tunnel failing with ECONNRESET · **RESOLVED** (2026-06-28)

Mobile app reported "backup cannot be processed / sync failed" for some assets. Server logs
showed `ECONNRESET` during multipart upload (`multer` middleware) — the TCP connection was
closed before the upload completed.

Root cause: without `chunked_encoding`, Cloudflare Tunnel's edge node buffers the entire
request body before forwarding it to cloudflared. For large photos/videos, this hits
Cloudflare's request processing timeout, causing it to drop the upstream connection, which
immich-server sees as an unexpected client disconnect.

**Fix (PR #192):** Added three fields to the `origin_request` block in the Cloudflare Tunnel
ingress config:

- `chunked_encoding = true` — enables streaming of the request body without buffering the
  entire payload at the edge first; this is the primary fix.
- `write_timeout = "600s"` — covers the upload leg (default: 30s, far too short for large videos)
- `read_timeout = "120s"` — covers origin processing time after the upload

The `moved {}` blocks in the same PR also prevented destroy+recreate of the live tunnel config
and DNS record when renaming resources for the Cloudflare provider v4 → v5 migration.

---

### REL-027 — Vault unseal-helper CLI major bump: 1.21.4 → 2.0.3 · **RESOLVED** (merged 2026-07-04, verified live 2026-07-06)

Renovate PR #204 only bumps `kubernetes/system/vault/unseal.yml`'s CLI image — the actual
Vault server version comes from the Helm chart default and is untouched. Risk was
functional (the automated unseal script from REL-007 could silently break on a restart
if CLI 2.0 changed flags/output), not a data-format risk.

**Found already merged and running, never marked resolved:** PR #204 merged 2026-07-04
(commit `3754f24`); this finding just sat as "PLANNED" for two days afterward with no one
re-checking it. Re-verified properly on 2026-07-06 rather than trusting "the pod is
Running" alone:

- Took a real raft snapshot first (`vault operator raft snapshot save`, pulled out via
  `kubectl cp`) as insurance, per the runbook's own step 2.
- **Forced a real test of the unseal path**, not just confirmed the image tag: deleted
  the live `vault-0` pod (`kubectl delete pod -n vault vault-0`) to force a genuine
  re-seal-on-restart, then watched it recover. `vault-unseal`'s own pod logs show
  `"Unseal attempt done"` timestamped right at the restart, and `vault status`
  immediately after confirms `Sealed: false`. This is real proof the CLI 2.0.3 unseal
  script still works correctly against the live server — not an assumption from the
  image tag alone.
- Full runbook: `docs/runbooks/pending-major-upgrades.md` (also corrected there —
  it still described this as "not yet executed").

---

### REL-028 — Postgres for Nextcloud + Paperless major bump: 16.14 → 18.4 · **RESOLVED** (2026-07-04)

Renovate PR #214 bumped two independent bare `StatefulSet` Postgres instances
(`postgres-nextcloud`, `postgres-paperless`) — not the Authelia CNPG cluster, which has no
pinned tag and is untouched. Executed both via dump/restore into a fresh PVC (PR #255
nextcloud, PR #257 paperless) rather than the unsafe bare image swap Renovate proposed.

Two things found only by actually running it (not in the original runbook):

- **PG18 requires a single `/var/lib/postgresql` mount**, not the old 16.x
  `/var/lib/postgresql/data` + `subPath` convention — the image's entrypoint refuses to start
  otherwise ("PostgreSQL data in /var/lib/postgresql/data (unused mount/volume)",
  docker-library/postgres#1259). Hit this on nextcloud first, fixed proactively on paperless.
- **Nextcloud's `config.php` used a different DB role name (`oc_dw`) than `POSTGRES_USER`
  (`nextcloud`)** — the fresh PG18 instance only had the `nextcloud` role from the env var.
  `pg_dump`'s `ALTER OWNER`/`GRANT` statements referencing `oc_dw` failed (230 harmless errors,
  data itself restored fine since `CREATE TABLE`/`COPY` ran as the connecting role), but
  Nextcloud itself couldn't authenticate until `oc_dw` was created manually with the same
  password from `config.php` and granted full privileges. Paperless didn't have this mismatch
  (`PAPERLESS_DBUSER` = `POSTGRES_USER` = `paperless`).

Verified: `occ status`/`occ user:list` on nextcloud, `django_migrations`/`documents_document`
row counts + a fresh paperless pod's celery logs on paperless, both apps reachable
(`https://nextcloud.woitzik.dev`, `https://docs.woitzik.dev`). pg_dump + a Velero on-demand
backup taken for each before touching anything; old PVCs (`nextcloud-db-data`,
`paperless-db-data`) kept declared (unused) as a rollback path, to be deleted after a
verified-good day per the runbook.

---

### REL-029 — Nextcloud app major bump: 30.0.17 → 34.0.1 · **RESOLVED** (2026-07-05)

Renovate PR #212 (closed, executed manually instead). Ran all four sequential `occ upgrade`
passes (30→31→32→33→34, PRs #259-260-261-262-264-265) — Nextcloud's updater refuses to skip
major versions. Two things found only by actually running the chain (not in the original
runbook):

- **The official image's entrypoint needs `su`'s CAP_SETGID** to rsync app files as `www-data`
  during a major-version transition — `capabilities: drop: ["ALL"]` broke this
  ("su: cannot set groups: Operation not permitted"), causing `occ upgrade` to fail with
  "the files of the app 'files' were not correctly replaced". Temporarily removed the
  capability drop for the duration of the migration, re-hardened (PR #265) once all 4 steps
  verified good.
- **`occ upgrade` must be run *after* the container entrypoint's own background file-sync
  finishes**, not just after the pod reports `Ready`/`Running` — running it too early hits a
  half-synced filesystem (`Failed opening required '.../symfony/polyfill-php82/bootstrap.php'`).
  Wait for `Initializing finished` in the pod logs first.

Verified: `occ status` (34.0.1.2, `needsDbUpgrade: false`), `occ user:list` (user intact),
`https://nextcloud.woitzik.dev` reachable. `occ app:list` showed 6 disabled apps
(`admin_audit`, `encryption`, `files_external`, `suspicious_login`,
`twofactor_nextcloud_notification`, `user_ldap`) — all opt-in/advanced features not used in
this single-user homelab install, not re-enabled per the runbook's "don't auto-re-enable
blindly" guidance.

---

### REL-030 — Immich Postgres (VectorChord) major bump: 14 → 16 · **RESOLVED** (2026-07-05)

Renovate PR #202 (closed, executed manually instead, PR #267). Same on-disk-format
incompatibility class as REL-028, on the largest PVC in the cluster (entire photo library
metadata + face/CLIP embeddings). VectorChord extension version itself unchanged (`0.4.3` on
both tags) -- only the Postgres major changed.

`pg_dumpall` (415748 lines, 180MB) into a fresh `immich-db-pg16` PVC; old `immich-db` kept
declared (unused) as rollback path. Verified post-restore: `vchord 0.4.3` and `vector 0.8.1`
extensions both loaded (`\dx`), `asset` table 11502 rows, `asset_face` 5456 rows matching
pre-migration counts. One transient error seen in `immich-server`'s first log lines
("infer_arbiter_indexes" on an `ON CONFLICT` upsert) turned out to be from ArgoCD self-heal
restarting the pod *before* the restore had finished (same race as REL-029) -- a plain pod
restart after the restore completed showed a fully clean startup. `https://photos.woitzik.dev`
and `/api/server/ping` both confirmed working post-migration.

All 4 originally-deferred Renovate major-version PRs (REL-027/028/029/030) are now done.

---

### REL-039 — Nextcloud/Paperless redis: RDB persistence failing on read-only rootfs, silently blocked all writes · **RESOLVED** (2026-07-05)

Live production outage: `nextcloud.woitzik.dev` stopped responding entirely (TCP connects,
zero bytes returned — PHP hanging, not Apache). Initially looked like a REL-029 capability
regression (re-hardening `capabilities: drop: ["ALL"]` on the nextcloud container after the
upgrade chain *did* independently break Apache's ability to spawn worker processes as
`www-data` — real bug, reverted — see the summary row below) but reverting that alone did not
fix the outage.

Actual root cause: `redis-nextcloud` (session/cache store, no PVC at all — only `emptyDir` at
`/tmp`) was still running with redis's *default* persistence settings. It had been silently
trying and failing to write RDB snapshots to the read-only rootfs the entire time
("Failed opening the temp RDB file ... Read-only file system"), and once enough writes
accumulated (redis's default `100 changes in 300 seconds` save trigger), this tripped redis's
own `stop-writes-on-bgsave-error` safeguard — which then refuses **all** subsequent writes,
including PHP's session writes via the Redis session handler. Every HTTP request hung
indefinitely trying to establish/read a session. `redis-paperless` had the identical
misconfiguration (no PVC, default persistence) and was one write-burst away from the same
failure — fixed proactively before it happened live.

Fixed both by invoking `redis-server` directly with persistence off
(`--save "" --appendonly no`), matching the existing `immich-redis`/valkey pattern exactly.
`redis-authelia` (`kubernetes/system/redis/`) is unaffected — it has an actual PVC and its
`--appendonly yes` is intentional.

Separately, also found and fixed: re-hardening the nextcloud container's `capabilities: drop:
["ALL"]` after REL-029's upgrade chain broke Apache permanently (not just during the upgrade)
— its main process needs CAP_SETGID to spawn `www-data` worker processes at all times, same
issue class as the existing SEC-012 comments on postgres/redis containers elsewhere in this
repo. Reverted; do not re-add this drop to this specific container.

**Lesson**: any redis/valkey container without a PVC must explicitly disable persistence
(`--save "" --appendonly no`) up front — the default settings will eventually fail against a
read-only rootfs regardless of how light the workload looks at first, and the failure mode
(silent write-blocking, not a crash) makes it very easy to misattribute to something else
entirely (this took investigating a capability change, a fresh pod, and Apache logs before
the actual redis logs were checked).

---

### REL-049 — Usenet stack effectively dead: 11 of 12 indexers disabled, German releases hard-filtered · **PARTIAL** (2026-07-05)

User-reported: "usenet stack not working." Root cause in NZBHydra2: 11 of 12 configured
indexers were `state: DISABLED_USER` (manually disabled at some prior point, not the
auto-recovering `DISABLED_SYSTEM_TEMPORARY` state), including the paid NZBGeek indexer —
leaving only SceneNZBs actually querying on any search.

- **Fix:** Re-enabled NZBGeek (`state` flipped to `ENABLED` in
  `/opt/media-acq/nzbhydra2/config/nzbhydra.yml`, container restarted). A live search
  test then surfaced NZBGeek's own `error code 104 "Membership Expired"` — a genuine
  billing issue, not a technical one; flagged to the user, needs renewal at nzbgeek.info.
  SceneNZBs (already `ENABLED`, real `apiKey` configured) confirmed fully functional —
  a live RSS sync test returned millions of real results.
- **Second bug found chasing a related complaint ("I have paid SceneNZBs, German
  releases should be in there")**: Sonarr's only language profile hard-restricted to
  English-only. Sonarr v4 still enforces a legacy allowed-languages list that filters
  releases out **before** custom-format scoring ever runs — so the repo's
  already-correctly-configured `German DL`/`German Audio` custom formats could never
  fire, no matter how well-scored a German release was, because it never reached
  scoring at all. Fixed by adding German as an additional allowed language on that
  profile (cutoff stays English) via `PUT /api/v3/languageprofile/1`.
- **Not fixed (external dependency):** NZBGeek membership renewal — requires the user
  to actually pay/renew, not something fixable from this session.
- **Lesson:** "indexer configured with a real API key" and "indexer actually enabled"
  are two different states worth checking independently — the same applies to
  "custom format exists and is scored correctly" vs. "the release ever reaches
  scoring at all" (a profile-level allow-list can silently gate everything upstream
  of scoring).

---

### REL-050 — Jellyseerr requests permanently stuck "Processing" despite files existing; scan cadence tightened · **RESOLVED** (2026-07-05)

User-reported: "why aren't requested items being pulled in Jellyseerr." Initially
misdiagnosed as a scheduling issue (jobs only ran once daily) — manually triggering the
jobs didn't change anything, which was the tell that the real cause was elsewhere.

- **Root cause:** Jellyseerr's only configured Radarr server was marked `is4k: true`.
  For a non-4k request, Jellyseerr writes completion status against the `status4k`
  field on that mismarked server (which correctly reached `5`/Available) instead of the
  `status` field (stuck at `3`/Processing) the UI actually renders for regular requests.
  The download and import had both fully succeeded the whole time — this was a pure
  status-reporting bug, not a pipeline failure.
- **Fix:** Set `is4k: false` on the Radarr server config (`PUT /api/v1/settings/radarr/1`),
  re-triggered `radarr-scan`, confirmed both `status` and `status4k` reached `5`.
- **Also done, per explicit user request to reduce staleness ("mach das die scans
  öfter sind")**: `radarr-scan`/`sonarr-scan` jobs 1x/day → every 2h, `availability-sync`
  → every 3h; Radarr's RSS sync interval 30min → 15min (now matches Sonarr's existing
  15min).
- **Lesson:** a single boolean server-config flag (`is4k`) on the *only* instance of a
  service, mismarked, silently reroutes status writes to a field the UI never reads —
  if a Radarr/Sonarr server in Jellyseerr isn't genuinely a 4K-only instance, `is4k`
  must be `false`.

---

### REL-051 — PBS offsite backup to Google Drive: cron job missing was a deliberate user decision (insufficient Drive quota), not a bug; underlying throttling issue documented anyway · **DEFERRED (deliberate)** (2026-07-06)

Found via a systematic `ansible-playbook site.yml --check --diff` sweep across every
host group looking for the same class of drift that caught the Minecraft `data-2`/
`data-3` bug (DOC-005). Two live findings on `ct-mgmt-pbs-01`:

1. **The `pbs_rclone_gdrive_token` Vault value was stale relative to the live
   `/root/.config/rclone/rclone.conf`** — the live file's OAuth token had a June 19
   expiry (auto-refreshed live by `rclone` since; OAuth access tokens self-refresh via
   the `refresh_token`, so an expired `expiry` timestamp alone isn't broken) while
   Vault's stored value was from an *even older* snapshot (April 4 expiry). A real
   Ansible run against this host would have overwritten the live, working config with
   the stale one.
2. **The offsite sync cron job does not exist on the live host at all** (`crontab -l`
   returns empty) — `docs/backup-strategy.md` still claimed "Daily at 04:00" was
   active. `/var/log/pbs-to-gdrive.log` shows the job ran (and mostly failed) nearly
   every day from 2026-05-04 through 2026-06-14, then stopped being invoked entirely.
   **Confirmed with the account owner: this was intentional** — they disabled it
   themselves around then because the destination Google Drive account doesn't have
   enough free space for the PBS datastore. Not a bug, just a doc that was never
   updated to say so.

**Root cause of the near-daily failures, found by running a real (bounded, 60s)
manual sync and reading rclone's own error output**: the sync isn't actually broken in
the credential/config sense — it makes real progress (confirmed files being copied)
— but Google Drive's API throttles hard on PBS's chunked storage format (7,692+
individual small files just in the portion observed, out of a `.chunks` directory with
65,538 subdirectories by design). Observed transfer rate: ~1.6 KiB/s,
**ETA displayed by rclone itself: ~12 weeks** for the initial full sync of 11.65 GiB.
Errors were `context deadline exceeded` on `list directory` calls — consistent with
Drive API per-file-operation rate limiting, not a network or auth problem. This means
the daily cron job's failures weren't transient — the *design* (syncing a many-small-
files chunk store directly to Drive) cannot complete an initial baseline sync in a
single day's window, so every run for 6 weeks was doomed to either time out or get
killed before finishing, matching the log exactly.

- **Fixed:** Vault's `pbs_rclone_gdrive_token` updated to match the current live
  (self-refreshed) token, so a future Ansible run won't regress a working credential —
  worth keeping current even with the cron job disabled, in case this gets revisited.
- **Also found while reading the role:** `ansible/roles/pbs/tasks/main.yml`'s "Force
  restart PBS Container" task (`pct stop 110 && sleep 3 && pct start 110`) had
  `changed_when: true` unconditionally and no guard — it restarted the live PBS
  container on *every* Ansible run against `mgmt_nodes`, not just the one-time bootstrap
  it was clearly written for (adding a bind-mount line to `110.conf`). A real backup
  job interrupted mid-run by an unrelated Ansible pass would be a self-inflicted
  version of this same finding. **Fixed** — moved to a `notify`/`flush_handlers`
  handler so it only fires when the bind-mount task actually changes something.
- **Fix (deliberately disabled, matching the account owner's actual decision):**
  `ansible/roles/pbs/tasks/main.yml`'s cron task now sets `state: absent` explicitly
  (was `present`, which is what silently kept trying to reintroduce it every Ansible
  run despite someone removing it live) — the rclone config and sync script stay
  deployed (harmless, ready to re-enable), only the schedule itself is off. Removed
  the live crontab entry to match.
- **Underlying throttling problem still documented, for if this is ever revisited:**
  even before the quota ran out, the sync mostly failed daily anyway. A manual bounded
  test sync showed why: Google Drive's API throttles hard on PBS's chunked storage
  format (tens of thousands of small files) — ~1.6 KiB/s observed, rclone's own ETA
  ~12 weeks for an initial full sync of 11.65 GiB. `context deadline exceeded` errors
  on `list directory` calls, consistent with per-file-operation API rate limiting, not
  a network or auth problem. **If offsite backup is revisited with a Drive plan that
  has enough space, this throttling issue would still need solving separately** —
  bundling chunks into fewer/larger archives before syncing, or picking a destination
  better suited to a many-small-files backup format, not just re-enabling the cron job.
- **Lesson: "the daily job ran and sometimes reported failure" was previously
  invisible** — nothing alerts on this cron job's own success/failure (the
  `healthchecks.io` ping at the end of the script only fires on a fully successful
  run, so its *absence* would need active monitoring of the check's own dead-man's-
  switch, which apparently wasn't being watched either). A backup you haven't verified
  completing isn't a backup.

---

### REL-052 — First real, live-verified PBS restore test; found the offsite gap REL-051 leaves is bigger than it looked · **RESOLVED** (2026-07-06)

`DISASTER-RECOVERY.md` documented the PBS restore procedure but nothing in this repo's
history indicates it had ever actually been executed and verified end-to-end — a written
runbook that's never been tried is a guess, not a tested procedure.

- **Test performed:** restored `ct-srv-atlantis-01`'s (vmid 204) most recent PBS snapshot
  (2026-07-06 01:04) to a scratch vmid (999) on the same host, alongside the still-running
  original — a genuine `pct restore` from a real backup, not a dry run. Booted it, confirmed
  `systemctl is-system-running` → `running`, confirmed its Docker Compose stack auto-started
  from the restored config (`unless-stopped` policy) and came up healthy with real data
  intact (`.atlantis` state directory, `.terraform.d`). Destroyed the test container
  immediately after. The live original was never touched and stayed healthy throughout
  (confirmed `atlantis.woitzik.dev` still returned its normal `302` Authelia redirect).
- **Real gotcha found doing this, not previously documented:** a PBS restore recreates
  the container with the exact same static IP and MAC address as the original. Starting
  the restored copy while the original is still running (as opposed to a true full-loss
  scenario where the original is gone) causes a live IP/MAC conflict on the network.
  Caught this *before* starting the test container by inspecting its restored config
  first — set `net0` to `link_down=1` with a different MAC prior to `pct start`. Added
  this as an explicit step in `DISASTER-RECOVERY.md`'s Tier 1 so a future
  restore-while-original-still-exists test (or a real partial-loss recovery run
  alongside other still-healthy nodes) doesn't cause a self-inflicted outage.
- **Bigger finding, surfaced by writing up this test properly:** `DISASTER-RECOVERY.md`'s
  Tier 1 previously said a total loss of both `mini`'s ZFS pool and the USB PBS storage
  disk could still be recovered "first from the Google Drive offsite copy." Cross-checking
  this against REL-051 (found the same day): that offsite copy has been deliberately
  disabled by the account owner (insufficient Drive storage) and, even in the weeks it did
  attempt to run, never got far enough for a usable restore given the Google Drive API
  throttling issue REL-051 documents. **The actual current state is that a simultaneous
  loss of both PBS storage layers has no working recovery path at all** — corrected the
  runbook to say so plainly rather than pointing at a step that would fail.
- **Lesson: a disaster-recovery runbook's accuracy has to be checked against the *current*
  state of every backup it depends on, not just written once and trusted** — this doc's
  Stage-3 reference was accurate when originally written, but silently became wrong the
  moment the offsite sync was disabled, and nothing flagged the mismatch until this test
  prompted a direct cross-check.
- **Effort:** Small — done.

---

### REL-053 — Immich major bump v2.7.5 → v3.0.1, last deferred Renovate major finally executed · **RESOLVED** (2026-07-06)

The immich-server/immich-ml major bump (PR #273, `v2.7.5` → `v3.0.1`) had sat deferred
since it was opened — flagged in earlier sessions as needing its own dedicated pass
rather than a blind merge, matching the same caution applied to the other 2026-07
majors (REL-027/028/029/030). Checked the actual v3.0.0 upstream release notes before
proceeding: breaking changes are almost entirely API-endpoint changes affecting
third-party integrations, not core web/mobile functionality, and the one genuine
migration warning (dropping `pgvecto.rs` support) didn't apply — this repo's Postgres
was already on VectorChord (REL-030, 2026-07-05). The PR's diff also still listed a
postgres `14→16` bump that had *already happened* in REL-030; confirmed via
`mergeStateStatus: CLEAN` that merging it wouldn't revert that (git's 3-way merge saw
both sides already agreeing on `16`, a no-op).

- **Fix:** took a real `pg_dumpall` backup first (guardrail #1, snapshot before any
  change touching running state), recorded `asset`/`asset_face` row counts as a
  before/after check (11553 / 5461), then merged PR #273 and let ArgoCD's `selfHeal`
  roll it out.
- **Verified live, not just "pods are Running":** confirmed both `immich-server` and
  `immich-ml` pods came up on the new image with 0 restarts, row counts identical
  post-migration (11553 / 5461 — no data loss), `GET /api/server/version` reports
  `{"major":3,"minor":0,"patch":1}`, and `photos.woitzik.dev` serves its login page
  (`200`).
- **Effort:** Small once actually attempted — the deferral itself had outlasted the
  actual risk, which turned out to be low for this specific major version.

---

### REL-054 — Kubeconform CI/pre-commit rate-limit fix (PR #306) was a mitigation, not durable · **RESOLVED** (2026-07-06)

PR #306 added kubeconform's `-cache` flag backed by `actions/cache`, keyed on the k8s
version + a hash of the manifest tree, to stop `raw.githubusercontent.com` 429s from
failing CI on PRs that touched zero Kubernetes manifests. Re-assessed per this audit
pass's Task 5: verified this was a **mitigation, not a fix** — it reduces repeat network
calls across cache-hit runs, but a cold cache (first run, evicted after 7 days unused,
or a manifest introducing a schema never seen before) still falls through to a live
network call, and a genuine network failure at that point is a **hard error**, not a
clean skip — `-ignore-missing-schemas` only suppresses true 404s, not 429s/timeouts.

**Proved this live**, not assumed: reran kubeconform against every manifest under
`kubernetes/` with a deliberately broken proxy (`https_proxy=http://127.0.0.1:1`, so
any network attempt fails immediately) using the `-cache` approach — a schema not
already in the cache directory hard-failed CI (`exit 123`), confirming the durability
gap is real, not theoretical.

**Fix:** vendored the JSON schemas for every built-in kind actually used under
`kubernetes/` into `ci/kubeconform-schemas/v1.31.0-standalone/` (15 files, 3.0 MB — the
15 built-in resources; the ~20 CRD kinds like `Application`/`IngressRoute`/`Certificate`
have no upstream schema in `yannh/kubernetes-json-schema` at all and stay skipped via
`-ignore-missing-schemas` either way, unaffected by this change). Both the pre-commit
hook and CI job now use `-schema-location` pointing only at this local directory —
removed the `actions/cache` step entirely, since there's nothing left to cache against.
Reran the same broken-proxy test against the new `-schema-location` setup: `Errors: 0`,
`exit 0` — fully offline, confirmed with network hard-blocked, not just "should work."

- **Refresh path documented:** `ci/kubeconform-schemas/README.md` — a PR introducing a
  new *built-in* kind not yet vendored needs one local `kubeconform -debug` run + `curl`
  to add the missing schema file, same one-time cost the old `-cache` approach had on
  its first-ever cold run, but now it's an explicit, reviewable commit instead of a
  silent live network dependency in CI.
- **Blast radius:** CI/pre-commit tooling only — no application manifests changed, no
  live cluster/host state touched.

---

### REL-057 — Autonomy-readiness task 4: recovery/self-heal loop, verified · **PARTIAL** (2026-07-07)

Report only, per instruction — no fixes applied, no risky changes. Verified each claim
against live state rather than trusting "it's configured so it must work."

- **cert-manager renewal: CONFIGURED, not yet proven.** `wildcard-woitzik-dev`'s only
  `CertificateRequest` is Revision 1, issued 2026-06-03 — it has never actually
  auto-renewed. `renewalTime: 2026-08-02` (30 days before `notAfter: 2026-09-01`) is
  correctly scheduled, but that's ~4 weeks in the future from this check (2026-07-07);
  there's no historical renewal event yet to point to as proof it actually works when
  the time comes.
- **ArgoCD self-heal: PROVEN, on everywhere.** All 41 live Applications have
  `syncPolicy.automated.selfHeal: true`, no exceptions found (`kubectl get applications
  -n argocd -o json`, checked every one programmatically).
- **Backups: schedule proven, completion/restore NOT proven — real live gap found.**
  Velero's `daily-backup` schedule has run reliably for 23+ days of history. But of the
  5 most recent runs, **2 actually failed** (2026-07-03, 2026-07-04) — `phase: Failed`,
  `HeadObject ... dial tcp 10.43.126.190:3900: i/o timeout` against Garage. This is
  separate from and later than the already-fixed REL-019 ENOSPC incident — a live,
  currently-unexplained ~40% recent failure rate that nobody was alerted to before
  REL-055's new `VeleroBackupFailed` alert (this session, task 2) existed. The 3
  `Completed` runs each carry 56–101 warnings (spot-checked one: mostly benign
  Kopia/socket-file noise — `reposerver-ask-pass.sock: unknown or unsupported`, a
  documented-safe Velero warning class — not individually audited further).
  **`kubectl get restores.velero.io -A` across the whole cluster: zero results, ever.**
  REL-052 tested a PBS (Proxmox Backup Server, hypervisor-level VM/CT) restore — a
  completely different system. The in-cluster, Velero-level restore path (the one that
  actually matters for "can this app's data come back after a PVC is lost without
  losing the whole VM") has never once been exercised. This is exactly the REL-023
  "backup ran ≠ backup restores" gap the instruction named, still open.
  - Confirmed the backup schedule's scope is `includedNamespaces: ["*"]` (all except
    `kube-system`/`kube-public`/`kube-node-lease`) — meaning the `garage` namespace
    itself is included in what gets backed up, which is precisely REL-003's documented
    circular dependency (Velero's own S3 backend is in-cluster Garage) — **not touched,
    it's on the skip-list** — but it's the concrete reason a from-scratch cluster
    recovery can't currently bootstrap cleanly: Garage needs restoring to get anything
    back, but Garage is also what everything (including its own backup) was stored in.
- **Not investigated further:** the exact cause of the 2 Garage `HeadObject` timeouts
  (transient network blip vs. a recurring pattern), and a full audit of the warning
  content across all 3 successful runs beyond the one spot-check.

**Effort:** Small — verification only, this section is the report.

---

### REL-058 — DHCP `home.lan` domain drift, DNS query-volume investigation part 1 · **CONFIGURED, awaiting apply** (2026-07-07)

DNS query volume grew from ~40k/7d to 1.8M/7d after the k3s migration. First root cause:
live-confirmed (`networkctl status` on a k3s VM) that DHCP is handing out `home.lan` as
the search-domain suffix, which kubelet then appends to every pod's `resolv.conf`
(standard `ClusterFirst` DNS policy behavior). With the pod default `ndots:5`, this
means every external hostname lookup also tries `<name>.home.lan` — and unbound has no
authoritative zone for `home.lan` (unlike `fritz.box`, which already has a real
stub-zone to the router), so every one of these recurses all the way out and fails.
Confirmed ~341ms average for these vs. instant for a local answer.

**Found live drift, not just a config gap:** `terraform/stacks/network/dhcp.tf` never
declared a `domain` attribute on any `routeros_ip_dhcp_server_network` resource, and
the last `terraform.tfstate.backup` on disk shows `domain: null` for every network —
yet the live DHCP lease clearly delivers `home.lan`. Either someone set it manually via
Winbox at some point (bypassing Terraform, against `CLAUDE.local.md`'s explicit rule),
or an apply after that state backup set it and it was never declared in code to catch
future drift. Couldn't get a live read of the router's current value directly (no
router credentials in this shell, and pulling real state needed backend init this pass
didn't do) — the fix doesn't depend on knowing which explanation is correct.

**Fix:** declared `domain = ""` explicitly on both `vlan_networks` (all VLANs) and
`vlan10_network` — forces Terraform to detect and correct this drift on the next
Atlantis apply regardless of the current live value, and prevents it from silently
reappearing.

- **Not yet applied** — Terraform network changes only go through Atlantis
  (`atlantis apply` comment), never applied locally, per `CLAUDE.local.md`.
- **Caveat:** existing DHCP leases keep `home.lan` until they renew or the client
  reboots — this won't take effect instantly fleet-wide even once merged and applied.
- See REL-059 for the unbound-side companion fix (answering `home.lan` locally instead
  of relying solely on removing it at the source) and the NTP query-volume finding.

**Effort:** Small — two-line Terraform change, `terraform validate`/`tflint` clean.

---

### REL-059 — unbound: answer `home.lan` locally, stop paying full recursion for NTP noise · **CONFIGURED, awaiting apply** (2026-07-07)

Companion to REL-058. Two fixes to `ansible/roles/unbound/templates/unbound.conf.j2`,
independent of whether/when the DHCP-side fix actually lands (existing leases keep
`home.lan` until renewal regardless):

1. **`local-zone: "home.lan." static`** — an empty static zone, answers NXDOMAIN
   instantly from unbound itself for anything under `home.lan` with zero recursion.
   There was never a real internal zone here to preserve; it was always just a leftover
   DHCP search-domain suffix. This is the immediate fix that doesn't wait on DHCP leases
   to renew.
2. **`local-data` overrides for `ptbtime{1,2,3}.ptb.de`** — these 3 hostnames (AVM/
   Fritz!Box's default NTP servers) accounted for ~24% of all DNS traffic, ~440k/7d
   queries. Traced the actual client IPs via AdGuard's own query log
   (`grep querylog.json`, not guessing): `192.168.178.20/23/25` — the **Fritz!Box's own
   LAN subnet**, not any k3s node or container. This volume is unrelated to the k3s
   migration; it was just noticed at the same time. Those 3 devices aren't identified
   or manageable from this repo, so instead of chasing them down, made answering them
   free: `local-data` serves the current real IPs (confirmed via `dig`, 2026-07-07)
   instantly from unbound's own zone with no upstream re-query, regardless of how often
   the unidentified devices ask or how short ptb.de's actual TTL is. This changes
   nothing about where the resulting NTP traffic goes, only the cost of answering the
   DNS query.
   - **Maintenance note, flagged not hidden:** if ptb.de ever rotates these IPs, NTP
     sync for whatever's using them silently starts failing instead of being visible as
     high DNS volume. An occasional `dig ptbtime1.ptb.de` is the cheap way to catch
     that.

**Validated, not just written:** no `unbound-checkconf` binary in this minimal image, so
validated by copying the rendered config (zero Jinja variables in this template — it's
static) into a disposable container from the same image and running
`unbound -c <file> -d -v`; got `Start of unbound 1.25.1` with no preceding fatal
parse error before the forced timeout, confirming the syntax parses. Test files cleaned
up off the live host afterward, nothing left behind, live `unbound.conf` untouched.

- **Not yet applied** — this is an Ansible-managed config file; the actual restart
  (`community.docker.docker_compose_v2 ... state: restarted`) happens via a normal
  playbook run, not something to trigger ad hoc outside that workflow.
- **Not addressed here:** the `ndots:5` pod-level tail (external names still try 3
  cheap, non-recursing cluster-suffix lookups before the bare name) — the `home.lan`
  fix above removes the expensive recursion; per-pod `dnsConfig.options: ndots:1` would
  be a further optional micro-optimization for specific high-QPS external-calling
  workloads, not applied broadly here given the blast radius of touching every
  Deployment for a much smaller marginal gain.

**Effort:** Small — one template file, config-validated against a disposable container
of the live image.

---

### REL-060 — paperless-gpt CrashLoopBackOff: v0.26.0's entrypoint breaks under `readOnlyRootFilesystem` · **RESOLVED, awaiting merge** (2026-07-07)

`paperless-gpt` had been `CrashLoopBackOff` since 13:43, traced to `icereed/paperless-gpt:v0.26.0` — the Renovate bump from PR #314, merged earlier the same day. `kubectl logs --previous` showed the exact failure: `addgroup: /etc/group: Read-only file system`. v0.26.0's container entrypoint added a startup `addgroup`/`adduser` step that fails outright under this Deployment's `readOnlyRootFilesystem: true` (SEC-012 hardening) — same failure *class* SEC-012's own comments already warned about for other images (an image's assumed-safe defaults turning out wrong), just not this specific image until now.

**Fixed:** rolled back to `icereed/paperless-gpt:v0.25.1` (the prior working tag) rather than relaxing the security context — the hardening is correct, the image's new startup behavior isn't compatible with it. Verified live: the new pod reached `1/1 Running` with a clean startup log (`Server started on interface :8080`, `Worker 0 started`), no `addgroup` error.

- **`icereed/paperless-gpt` added to `renovate.json`'s stateful/critical PR-only list** — it wasn't in that list before (fell into the general stateless auto-merge tier, which is exactly how v0.26.0 landed unreviewed via PR #314 today). Future bumps need manual verification against this security context before merging.
- **Live state note:** `paperless` is an ApplicationSet-generated Application (`homelab-apps`), not a standalone one — patching its `syncPolicy` directly to pause `selfHeal` for testing gets silently discarded, because the ApplicationSet controller re-templates its generated Applications from its own spec on every reconcile. Unlike every other selfHeal-pause done this session (postgres-cluster, argocd-manifests, monitoring-manifests — all standalone Applications), there's no clean way to pause selfHeal for a single ApplicationSet-generated app without touching the ApplicationSet itself (which would affect every app it generates). Verified the fix works via a live `kubectl apply` that held long enough to confirm the pod recovers, but **the live cluster reverts to the broken `v0.26.0` via selfHeal until this PR is actually merged** — not something a live-only fix can hold against.

**Effort:** Small — one tag rollback, one Renovate rule addition. The ApplicationSet selfHeal limitation above is a process note, not something fixed in this PR.

---

### REL-061 — cloudflare-ddns and nextcloud-cron 2h alert loop: dead token + stale-alert hygiene · **RESOLVED, awaiting merge** (2026-07-07)

Both `cloudflare-ddns` (cert-manager namespace) and `nextcloud-cron` (apps namespace)
appeared to be "failing on a ~2h loop." Root-caused each — they were two unrelated
problems that happened to produce the same symptom.

**cloudflare-ddns — a real, currently-live failure, silently masked:** `cloudflare-api-token-secret`
turned out to be a bare, hand-created Secret (`kubectl apply`'d once on 2026-06-02,
never touched since — not Vault/ExternalSecret-managed at all). Confirmed live via
Cloudflare's own `/user/tokens/verify` endpoint: `"Invalid API Token"`. Not the "old
global API key" hypothesis — the script already used a Bearer token correctly, the
token itself had simply gone dead. **This same secret is also what
`letsencrypt-production`'s `ClusterIssuer` uses for DNS-01 challenges** — meaning
cert-manager's own certificate renewal (already flagged unproven in REL-057) would
have failed had a real renewal been attempted before this was found.

The script itself made this worse: it never checked `"success"` in either Cloudflare
API response and always exited 0 regardless, so `KubeJobFailed` had nothing to alert
on even though DNS updates had been silently broken for an unknown period.

**Fixed:** found the exact same working token already in use by Terraform/Atlantis
for the `cloudflare` stack (`ansible` vault: `cloudflare_api_token`/
`vault_atlantis_cloudflare_api_token`) — verified live via Cloudflare's API (valid,
active, and both `GET` and a real no-op `PUT` against the actual
`cobblemon.woitzik.dev` record succeeded) before reusing it, rather than minting a new
token and risking the REL-048 dashboard bug (silently drops permission groups when
adding a 2nd one) again. Wired it into HashiCorp Vault (`secret/cloudflare`) with a
proper `ExternalSecret`, replacing the dead hand-created Secret — same fix pattern as
every other bare-Secret gap found this session. Verified end-to-end: manually
triggered the CronJob, got a real, correct result (`IP unchanged (178.202.47.0),
nothing to do`) instead of a masked failure. Also fixed the script to actually check
`"success"` in both API responses and exit nonzero on a real failure, so this class of
silent breakage can't recur invisibly.

**nextcloud-cron — a real but old, non-recurring failure, not actually still
happening:** the alert was firing on a Job from 2026-06-28/29, over a week old.
Current runs are all clean (`exitCode: 0`). Original failure's pods were already
garbage-collected by the time this was investigated — root cause not recoverable, and
given zero recurrence in a week-plus, not worth chasing further.

**The actual "2h loop" for both**: `failedJobsHistoryLimit: 1` keeps exactly one failed
`Job` object around, but nothing rotates it out until a *newer* failure replaces it —
it doesn't expire on its own. With no new failures for either job, the same stale
`Job` sat there indefinitely, and Alertmanager's `repeatInterval: 2h` (REL-055's
warning-tier route) kept re-notifying Discord for a problem that, for nextcloud-cron,
was already over a week gone. Deleted both stale `Job` objects live, and added
`ttlSecondsAfterFinished: 86400` to both CronJobs so a real failure gets 24h to be
investigated but doesn't linger and re-alert forever afterward.

- **Live-tested throughout**: token verified against the real Cloudflare API before
  and after wiring; the fixed CronJob triggered manually and produced a genuine
  (not masked) result; stale Job objects confirmed gone.
- **Not attempted**: a live ACME DNS-01 challenge to directly prove cert-manager's
  side works with the new token — the same token already proved `DNS:Edit` write
  access on this exact zone via the `PUT` test, which is what DNS-01 needs; triggering
  a real certificate operation just to double-confirm felt like an unnecessary risk in
  an already-broad fix.

**Effort:** Medium — the ddns token investigation (ruling out global-key first,
finding the dead token, finding a working replacement already in use elsewhere) took
longer than the mechanical CronJob hygiene fixes.

---

### REL-062 — 2026-07-07 near-nightly host thermal spikes: corrected root cause · **CORRECTED, PROPOSED, awaiting review** (2026-07-07)

**This section replaces an earlier version of this entry that had the root cause
wrong.** Leaving the correction visible rather than silently rewriting history,
matching how errors get handled everywhere else in this doc.

**Original claim (wrong):** that `ProxmoxHostHighTemp`/`KubeAPIServerDown` firing at
03:05 on 2026-07-07 was caused by PBS's `vzdump` job and Velero's Kubernetes backup
both starting at the literal same instant (03:00), and that staggering Velero's
schedule away from `vzdump` would address the stacking.

**Why it was wrong:** `mini` runs `Europe/Berlin` (CEST, UTC+2); the k3s VMs (where
Velero's CronJob schedule is evaluated) run UTC. `jobs.cfg`'s `vzdump` entry says
`schedule 03:00` — but that's 03:00 **local/CEST**, i.e. **01:00 UTC**. Confirmed
against `vzdump`'s own live task history: it has run 01:00–~01:15 UTC (occasionally
up to ~01:47 UTC) every single day for the past month, including 2026-07-07.
Velero's `0 3 * * *` schedule is 03:00 **UTC**. The two jobs are **2 hours apart in
real terms and have never overlapped**. The first fix attempted (moving Velero to
`0 1 * * *`, intending 01:00 as a 4-hour gap from a misread "03:00 UTC" `vzdump`)
actually moved Velero directly into `vzdump`'s real 01:00 UTC window instead of away
from it — caught before merge, not applied live, but flagging the mistake plainly.

**What's actually true, re-checked with a full week of history, not one night:**
queried `node_hwmon_temp_celsius` at 03:00–03:10 UTC for the 6 nights before the
alert fired:

| Date | Peak temp, 03:00–03:10 UTC |
|---|---|
| 2026-07-01 | 84.6°C |
| 2026-07-02 | 88.4°C |
| 2026-07-03 | 86.9°C |
| 2026-07-04 | **90.0°C** |
| 2026-07-05 | 82.6°C |
| 2026-07-06 | 81.6°C |
| 2026-07-07 (alert night) | 85.5°C measured (Prometheus's own scrape resolution) |

**Velero's own backup, alone, pushes host temperature into the 82–90°C range every
single night** — `vzdump` isn't a factor at all, confirmed. 2026-07-04 was *hotter*
than the night that actually alerted, and didn't trigger anything. 2026-07-07 wasn't
a special double-stacking incident — it was this same nightly pattern crossing the
alert threshold (and `for: 3m` sustain window) clearly enough to actually fire and
resolve. This has likely been happening, silently, near the edge of the alert
threshold, for at least a week.

**Corrected findings from the original investigation that still hold** (evidence
itself was real, just the "vzdump caused it" attribution was wrong):

- `node_load1{group="pve_hosts"}` peaked at **11.29 at 03:03:00 UTC** on an
  8-core/16-thread host on the alert night — a real, severe load spike, caused by
  Velero's own backup (`defaultVolumesToFsBackup: true` across every namespace —
  real kopia filesystem-backup CPU work, not vzdump).
- `journalctl -u k3s` on `vm-srv-k3s-11` really did show etcd `"apply request took
  too long"` warnings at 03:03:08 — genuine load-caused degradation, just caused by
  Velero alone, not a vzdump/Velero combination.
- CNPG's 2am backup and Renovate's `0 */2 * * *` are still correctly ruled out as
  contributors — that part of the original analysis was unaffected by the timezone
  error.

**Revised proposal:** moved Velero's schedule to `0 5 * * *` (05:00 UTC) — clear of
`vzdump`'s real 01:00–~01:15 UTC window and the existing 04:00 R2 offsite schedule,
as basic scheduling hygiene against a *future* real collision if either job's timing
ever changes. **This is explicitly not a thermal fix** — moving the hour doesn't
reduce how hot Velero's own backup workload runs the host, since Velero alone is
already sufficient to reach 82–90°C regardless of what time it runs. **Not applied
live** — left for review.

**The actual finding that matters here, restated plainly:** this isn't a rare
near-freeze from an unlucky coincidence — it's Velero's regular nightly backup
running this host to within a few degrees of a real freeze *every night*, and
2026-07-04 (90°C, no alert) shows the current 85°C/3m alert threshold has already
been silently grazed at least once without anyone noticing. Whatever the hardware
cooling plan turns out to be, this is a standing, recurring risk, not a one-time
event — worth treating with more urgency than the schedule-hygiene change above
implies on its own.

**Effort:** Medium — the correction took real re-investigation (a full week of
Prometheus history, not just the one incident night) to catch and fix properly
rather than just quietly editing the number.

---

### REL-056 — Renovate tiered auto-merge, config only · **CONFIGURED, awaiting review** (2026-07-07)

Autonomy-readiness task 1. Previously every Renovate PR needed a manual merge
regardless of risk — a patch bump to `blackbox-exporter` got the same manual-review
treatment as a Postgres major. Gated on task 2 (REL-055, Discord alert coverage) being
proven live first, per explicit instruction, since auto-merge without working failure
alerting is the wrong order.

**Two tiers, `renovate.json`:**

1. **Auto-merge** (patch/minor/digest only): stateless kubernetes-managed images, CI
   GitHub Actions, dev tooling (pre-commit hooks, Terraform providers). Gated on CI
   green (Renovate's own default behavior — it polls PR status checks before
   automerging regardless of GitHub branch-protection config) plus a 3-day
   `minimumReleaseAge` soak, so a bad upstream release doesn't land same-day.
2. **PR-only** (all update types, not just major): a named list of stateful/critical
   packages — `hashicorp/vault`, `ghcr.io/authelia/authelia`, `dxflrs/garage`,
   `vaultwarden/server`, `postgres`, `ghcr.io/immich-app/postgres`, `redis`,
   `valkey/valkey`, `nextcloud`, `paperlessngx/paperless-ngx`, `gitea/gitea`,
   `ghcr.io/immich-app/immich-server`, `ghcr.io/immich-app/immich-machine-learning`,
   `velero/velero-plugin-for-aws` — grouped into one PR per bump wave, labeled
   `stateful-critical`. All majors, any package, stay PR-only too (existing behavior,
   kept), labeled `major-update`, one PR per package (not grouped — each major is its
   own migration).
3. `docker:pinDigests` + `helpers:pinGitHubActionDigests` presets added for
   determinism, per instruction.

**Judgment calls made beyond the literal named list** (Vault, Authelia, Longhorn*,
Garage, and "databases"), flagged for the account owner to correct if wrong:

- `redis`/`valkey/valkey` classified as stateful/critical even though often used as
  cache rather than data-of-record — cheap to be conservative here, bumps are
  infrequent.
- `vaultwarden/server` added — not literally a database, but a credential store; its
  own AUDIT.md entries already treat its DB as protected critical state.
- `nextcloud`, `paperlessngx/paperless-ngx`, `gitea/gitea`,
  `ghcr.io/immich-app/immich-server`/`immich-machine-learning` added — each needs a
  manual data migration on major bumps (REL-028/029/030/053 all required dump/restore
  or multi-step upgrades), and REL-020's near-miss showed silent breakage in this class
  of app is easy to miss.
- `velero/velero-plugin-for-aws` added — not stateful itself, but a broken backup
  plugin silently breaks every backup; blast radius alone justifies PR-only.
- Deliberately left in the auto-merge tier despite having their own persistent state:
  `headscale` (SQLite of node registrations, recoverable by re-registering),
  `home-assistant` (automation history, not this repo's stated critical-state list).
  Move either into the critical tier if that recoverability assessment is wrong.

*No Longhorn in this cluster currently (confirmed via `kubernetes/` search) — CNPG/PVC
storage runs on `local-path`/`nfs-client` per the REL-010/028 migrations, not Longhorn.
Named in the instruction as a general "what belongs in this tier" example; no matching
package exists to add.

**Not yet enabled live:** this PR is config only, not merged. Per instruction, the
account owner reads the tiering before it takes effect.

**Effort:** Small — one file, `renovate-config-validator` confirms it parses and
resolves cleanly.

---

### REL-035b — Memory-overcommit regression guard: two-tier model, not one sum · **RESOLVED** (2026-07-07)

Follow-up to REL-035. That pass fixed CPU-scheduling contention (`cpu.units`) but left
"no CI/lint gate stops total allocation from creeping back up" as an explicitly open
gap. A guard was built for it (below, "first cut"), then reworked once the first cut's
own model turned out to be wrong.

**First cut (2026-07-06) — one sum, one ceiling:** summed `dedicated` memory across
every VM *and* CT together (85.0 GB: 57.0 GB across 9 LXCs + 28.0 GB across 3 VMs)
against a single 50 GB ceiling (64 GB physical − 14 GB reserved for ARC/host/margin).
Shipped red on purpose (35.0 GB "overage"), with trim options listed for the account
owner including calling `ct_dmz_games_01`'s 8 GB allocation the "smallest-blast-radius
trim candidate."

**Why that was wrong, found on re-check (2026-07-07):** the single sum conflates two
different RAM physics that must not be added together:

- **VM `dedicated`** (`vm.tf`): Proxmox pre-allocates this as real qemu process memory
  the moment the VM starts. This *is* a host reservation.
- **LXC `dedicated`** (`lxc.tf`): a cgroup `memory.max` — a soft ceiling the kernel only
  enforces if the CT actually tries to use that much. It reserves nothing on the host
  up front.

Summing both against one ceiling systematically overstates real pressure. Proven live:
`free -h` on `mini` showed `41Gi used / 62Gi total / 21Gi available` — the host was
*not* under memory pressure — while the old model's 85 GB "allocated" already implied a
severe overcommit. The CT side of that 85 GB was almost entirely soft limits nobody was
using: `pct exec <id> -- cat /sys/fs/cgroup/memory.current` showed real usage well
under each CT's configured ceiling across the fleet.

The `ct_dmz_games_01` "smallest-blast-radius trim candidate" call was also wrong on its
own terms: its Terraform comment already documents that it was deliberately cut
16→8 GB on 2026-07-04 under REL-035, with the same "observed peak ~4.7 GB" headroom
math the first cut re-derived — it wasn't a fresh trim candidate, it was already the
result of one.

**Rebuilt (2026-07-07) — two tiers, different physics, different consequences:**

1. **Hard gate (fails CI/pre-commit):** sum of VM reservations + `zfs_arc_max` + a fixed
   host reserve, against a 44 GB ceiling.
   - VM reservation = `dedicated`, not `floating` (the ballooning floor), for every VM —
     even the 3 k3s VMs that do set `floating`. Live `qm status <id> --verbose` found
     all 3 sitting at their full `dedicated` ceiling, not deflated to `floating`:
     Proxmox only deflates once it has *already* detected host pressure, and this guard
     exists to catch a pressure event *before* it happens. Gating on the optimistic
     floor would understate exactly the risk being guarded against.
   - Math: VM `dedicated` sum 28.0 GB (12+8+8 GB across the 3 k3s VMs), plus ARC 4 GB,
     plus host/hypervisor reserve 6 GB, totals **38.0 GB** — 6 GB under the 44 GB
     ceiling, green.
   - `ai-01`'s 32 GB (`ct_srv_ai_01`, LXC) and all 3 VMs' `dedicated`/`floating` values
     are unchanged by this task — `ai-01` is a CT (soft-check side, not hard-gate), and
     its sizing plus the VMs' are incident-justified (REL-012/REL-016 Ollama/etcd
     headroom), not this task's to touch.
   - Failure message still names REL-016 explicitly: this ceiling exists to prevent a
     repeat of the ZFS I/O stall-under-RAM-pressure host-freeze.
2. **Soft check (warns, never fails CI):** sum of LXC `dedicated` limits (57.0 GB across
   9 CTs) vs. physical RAM (62 GB) — currently under, so silent. Only fires a warning if
   CT limits exceed physical RAM outright, and even then does not affect the script's
   exit code — CT limits are soft ceilings, not reservations, so they must never block a
   build on their own.

**Built:** `scripts/check-host-memory-overcommit.py` rewritten in place (same file, same
pre-commit hooks and CI job — `host-memory-overcommit-guard` — just reworked
exit-code/output behavior); hook and CI job descriptions updated to describe the
two-tier model instead of the single sum.

- **Effort:** Small — script rewrite plus this doc correction. No Terraform values
  changed.

---

### REL-057b — Velero backup failures root-caused: CNPG and Velero shared one bucket · **RESOLVED** (2026-07-07)

Root-caused the ~40% recent Velero backup failure rate flagged in REL-057 (2 of last 5
daily runs failed, `HeadObject` timeout against Garage). Ruled out the obvious
suspects with live evidence before landing on the real cause:

- **Not Garage CPU/memory load**: queried Prometheus for the exact failure windows
  (2026-07-03/04, 03:00 UTC) — Garage was idle, ~9 MiB RSS, negligible CPU, nowhere
  near its 1 CPU / 1Gi limits.
- **Not a Garage crash/restart**: `kube_pod_container_status_restarts_total` flat
  across both windows.
- **A real but coincidental finding, not the cause**: both the NFS server
  (`ct-srv-nfs-01`, backs the `archive` ZFS pool Garage's data PV lives on) and `mini`
  itself rebooted on 2026-07-04, after both failures — a `dmesg` hung-task trail on the
  NFS host looked promising at first but turned out to postdate the failures entirely
  (ring buffer cleared by the reboot), so it couldn't be correlated. Left as a loose
  end, not chased further since the real cause was found separately.

**The actual cause**: `kubernetes/system/postgres/cluster.yml`'s CNPG cluster
(`postgres-authelia`) had its own `barmanObjectStore` WAL/base-backup archiving pointed
at `s3://velero/cnpg-postgres-authelia` — **the same Garage bucket Velero itself owns**.
Confirmed live: `kubectl get backupstoragelocation default -n velero` showed
`phase: Unavailable`, `message: 'invalid top-level directories: [cnpg-postgres-authelia]'`
— Velero's own bucket-validation logic doesn't tolerate an unrecognized top-level
directory and periodically flags the whole location unavailable. `garage bucket info
velero` confirmed two independent writers (access keys aliased `velero` and
`cnpg-backup`) sharing one bucket, 18711 objects, 200GB. This explains the
intermittent (not constant) failure pattern: whether a given backup run lands during
an Available or Unavailable window depends on Velero's own periodic validation timing
relative to CNPG's writes.

**Fixed**, in the exact order needed to never leave Authelia without a valid backup:

1. Created a new, separate Garage bucket (`cnpg-backups`) and a scoped access key
   (RWO on that bucket only) — one bucket per *backup system*, not per database, so a
   future second CNPG cluster lands under its own prefix (`s3://cnpg-backups/<name>`)
   instead of colliding again.
2. Repointed `cluster.yml`'s `destinationPath` to `s3://cnpg-backups/authelia` and
   `external-secret.yml`'s Vault properties to the new scoped credential (added to the
   existing `secret/garage` Vault path as `cnpg-backups-access-key-id`/
   `cnpg-backups-secret-access-key`, alongside the pre-existing `velero-*` properties).
3. **Verified before deleting anything**: triggered a real, on-demand CNPG `Backup` —
   completed, `destinationPath: s3://cnpg-backups/authelia`, confirmed live via `garage
   bucket info cnpg-backups` (6 objects, 12MB). Forced a WAL switch
   (`pg_switch_wal()`) and confirmed a 7th object landed — both base backup *and*
   continuous WAL archiving proven writing to the new bucket before touching the old
   one.
4. Only then deleted the old `cnpg-postgres-authelia/` prefix from the `velero` bucket
   (3632 objects) via a disposable `aws-cli` pod using Velero's own credential (already
   scoped to that bucket).
5. **`BackupStorageLocation` flipped back to `Available`** within ~30s of the deletion
   completing — confirmed live, not inferred.

**Live-tested throughout** (ArgoCD `postgres-cluster` Application's `selfHeal`
temporarily disabled during testing, same pattern as REL-042/055, restored after) —
manifests committed to git match exactly what was verified live, not written blind
and hoped to match.

- **Blast radius**: Authelia's CNPG backup destination only. The live database itself
  was never touched — only where its WAL/base-backup archive writes to. Old backup
  data was deleted only after the new chain was independently confirmed working.
- **Follow-up, deliberately not bundled here**: Garage bucket management (`cnpg-backups`
  and the pre-existing `velero`/`loki-data`/`terraform-state` buckets) is entirely
  hand-created, zero Terraform/GitOps management — a real IaC gap, tracked separately
  so it doesn't entangle with this auth-critical fix.

**Effort:** Medium — mostly investigation (ruling out Garage load/crash, chasing the
NFS-host dead end) before finding the actual cause; the fix itself was a clean,
verifiable bucket split.

---

### REL-055b — ArgoCD metrics port root-caused: k3s NetworkPolicy `namespaceSelector: {}` doesn't work · **RESOLVED** (2026-07-07)

REL-055 flagged `argocd-application-controller`'s metrics port (8082) as unreachable
and left it a GAP — `/proc/net/tcp` (IPv4-only) showed nothing listening, and
`--metrics-port` is documented to default to 8082 with no flag needed, so the earlier
pass concluded the metrics server itself wasn't starting. That conclusion was wrong,
and the real cause was more interesting.

**Corrected the earlier misdiagnosis first:** `/proc/net/tcp6` (checked this pass, not
before) showed a genuine `LISTEN` entry on `:::8082` — Go's dual-stack listener binds
one IPv6 socket that also serves IPv4-mapped connections, and that never shows up in
the IPv4-only `/proc/net/tcp` table. The app was listening the whole time; the earlier
check only looked at half the picture.

**Then found the actual blocker**, methodically: `curl` from another pod to the
Service, then directly to the pod IP, then to a freshly-recreated pod (ruling out
stale conntrack/veth state) — all `Connection refused`. But `curl` from *inside* the
pod's own network namespace to `127.0.0.1:8082` and to its own pod IP both worked
instantly, and the kubelet's own readiness probe (`httpGet :8082/healthz`) was passing
continuously (`Ready: true`, zero `Unhealthy` events). That pattern — reachable from
inside the pod and from the kubelet, refused from every other pod — pointed at
NetworkPolicy, even though `argocd-application-controller-network-policy`'s
`from: [{namespaceSelector: {}}]` rule should, per the upstream Kubernetes API spec,
allow exactly this traffic.

**Proved it live**: temporarily deleted the NetworkPolicy entirely — the metrics
endpoint immediately became reachable, returning real `argocd_app_info` data.
Re-added it with the identical `namespaceSelector: {}` rule — immediately blocked
again. Tried the more explicit `namespaceSelector: {} + podSelector: {}` combined
form — still blocked. Replaced the rule with `ipBlock: cidr: 10.42.0.0/16` (the
cluster's actual pod CIDR) — worked instantly. **k3s's built-in kube-router
NetworkPolicy controller does not correctly enforce a bare `namespaceSelector: {}`
"allow from all namespaces" rule**, at least in the version running here — a real
enforcement bug/limitation, not a misconfiguration in this repo.

**Checked blast radius**, not just the one port: all 6 of ArgoCD's other
NetworkPolicies existed live (none git-tracked — same orphan-config class as
REL-014/035/042, present since the original 2026-05-31 manual bootstrap). 4 more
(`applicationset-controller`, `dex-server`'s port 5558 rule, `notifications-controller`,
`repo-server`'s port 8084 rule) used the identical broken `namespaceSelector: {}`
pattern on their own metrics/cross-component ports — meaning ArgoCD's other component
metrics were equally unreachable, not just the application-controller's. Fixed all 5
with the same `ipBlock` pattern in one file. Left the policies using explicit
`podSelector` matches alone (dex-server's primary rule, redis, repo-server's primary
rule, argocd-server's unrestricted rule) — those already worked correctly.

**Wired end-to-end**: added `argocd-metrics` `ServiceMonitor` (co-located in
`kubernetes/system/monitoring/`, matching the cert-manager/Velero pattern) — confirmed
live via Prometheus's own targets API (`up`) and a real query
(`argocd_app_info`, 42 results, real health/sync status per app). This is the
Prometheus-side visibility REL-055 couldn't get to; it's additive to, not a
replacement for, REL-055's notifications-controller Discord path (deliberately did not
add a second Alertmanager rule for the same condition — would double-alert the same
event through two channels).

- **Live-tested with real traffic, not assumed**: every step (delete-policy test,
  alternate-syntax test, `ipBlock` test, ServiceMonitor scrape) was verified with an
  actual `curl`/Prometheus-API result before moving to the next, and diagnostic
  NetworkPolicy edits were restored/finalized immediately after each test — no window
  where the controller was left unprotected longer than the ~10s test itself took.
- All 5 NetworkPolicies and the ServiceMonitor added to git and to their respective
  Applications' include globs (`argocd-manifests`, `monitoring-manifests`) — same
  discipline as every other orphan-config fix this session.

**Effort:** Medium — the IPv4/IPv6 misdiagnosis correction and the systematic
elimination (Service → pod IP → fresh pod → intra-pod → NetworkPolicy) took longer
than the fix itself, which was a one-line-per-policy syntax change.

---

### REL-063 — PBS `vzdump` failure streak root-caused: safety net was reliable throughout · **CONFIRMED, already fixed outside this repo** (2026-07-07)

Flagged in passing during REL-062: `vzdump` (PBS's hypervisor-level backup — the
*only* backup layer that's ever had a real, live-tested restore, REL-052) had shown
`ERROR` status on several recent nights. Given this is the safety net under the whole
cluster, root-caused it properly rather than leaving it as a loose end.

**Full picture, not just the 3 nights first noticed:** 7 consecutive failures, not 3 —
2026-06-26 (an off-schedule 14:07 run), then every single scheduled night from
2026-06-27 through 2026-07-02. Pulled the actual task log for all 7 via
`pvenode task log <UPID>`, not just the summary status.

**Every single failure is the identical error, same VM, no variation:**

```text
INFO: Finished Backup of VM 302 (...)
INFO: Starting Backup of VM 9000 (qemu)
ERROR: Backup of VM 9000 failed - timeout: no zvol device link for 'base-9000-disk-0' found after 300 sec.
INFO: Backup job finished with errors
```

VM 9000 is `tpl-debian-13-cloudinit` — a **stopped template**, not a running guest
(`qm list` confirms: `STATUS stopped`, and it's the only VMID in the 9000+
template-numbering range on this host). Its disk is a ZFS `base-9000-disk-0` volume
— the read-only linked-clone source Proxmox uses for cloning new VMs from, not a
disk meant to be independently vzdump'd the normal way. This is a known category of
Proxmox+ZFS quirk: `base-*` template volumes don't always present a normal zvol
device symlink the way a regular VM disk does, and `vzdump` waiting on that symlink
appearing can time out.

**Critically: VM 9000 was always the *last* item attempted, after every real guest had
already finished successfully.** Checked each failure log for the full sequence, not
just the error line — every real, data-bearing guest (`ct-mgmt-pbs-01`,
`ct-srv-docker-01`, `ct-srv-ai-01`, `ct-srv-media-acq-01`, `ct-srv-jellyfin-01`,
`ct-srv-atlantis-01`, `ct-srv-nfs-01`, `ct-dmz-proxy-01`, `ct-dmz-games-01`, and the 3
k3s VMs) **completed its backup successfully every single one of those 7 nights.**
The "job failed" status was real, but it meant "the tail-end backup of a template with
no unique data timed out" — not "the safety net didn't run."

**Already fixed, confirmed live — not by this investigation:** `jobs.cfg`'s current
`vzdump` config has `exclude 9000`, and the actual command line PBS logged starting
2026-07-03 (`vzdump --all 1 ... --exclude 9000 ...`) confirms it took effect exactly
when the failures stopped. Someone (not this session) fixed this already; this pass
just confirmed and documented what actually happened and why.

**Direct answer to "is the hypervisor safety net actually reliable, or just proven
once":** reliable, for real guests, throughout — including during the failure streak.
The one thing that wasn't reliable was backing up a non-critical template that holds
no unique data (it's a clone source, re-creatable from the same base image), and that
was already fixed 5 days before this check.

- **Real gap, though**: the fix (`exclude 9000` in `/etc/pve/jobs.cfg`) lives entirely
  in Proxmox-native config, outside this repo's Terraform/Ansible management — same
  class of "real change, zero IaC trail" gap already flagged for Garage bucket
  management in REL-057b. Not fixed here (this task was report-only per instruction),
  but worth folding into that same follow-up IaC-coverage pass rather than opening a
  third one.
- **Not investigated further**: whether other templates might hit the same issue if
  added later — there's only the one template VMID on this host right now, so a
  broader `exclude` range (e.g. all `9xxx` VMIDs) wasn't necessary to recommend as a
  preventive measure, just noting it as a future consideration if more templates get
  added.

**Effort:** Small — the failures were already fixed; this was verification and
root-cause documentation, not remediation.

---

### REL-064 — Post-Velero-fix thermal recheck · **PENDING, 0/3 nights observed** (2026-07-07)

REL-062 (corrected) established that Velero's own nightly backup, alone, pushes host
temperature to 82–90°C every night regardless of `vzdump` — the schedule move to
`0 5 * * *` (merged in PR #327, live on `main` as of 2026-07-07 16:03 UTC) is
explicitly **hygiene, not a thermal fix**. Separately, physical cooling work
(cleaning/repaste) is being done outside this repo. This entry tracks the open
question: after both changes, does peak nightly temperature actually drop below 80°C,
or does Velero's IO/CPU load alone keep driving it high regardless of what time it
runs?

**Why this can't be answered yet:** the schedule change only took effect today
(2026-07-07); the first backup run under the new `05:00 UTC` schedule hasn't happened
yet (next occurrence: 2026-07-08 05:00 UTC). There is no fabricating this — it needs
2–3 real nights of Prometheus data after both the schedule change and the physical
cooling work are actually in place. Marking this `PENDING`, not `PROPOSED` or
`RESOLVED`, is deliberate: this is the same "PROVEN-when-the-graph-drops" standard
applied to the DNS fixes (REL-058/059) and Velero backup reliability (REL-057b) earlier
this session — a merged config change is not the same as a proven outcome.

**Pre-fix baseline, already established (from REL-062's corrected investigation, for
comparison against the recheck data):**

| Date | Peak temp, then-03:00–03:10 UTC window |
|---|---|
| 2026-07-01 | 84.6°C |
| 2026-07-02 | 88.4°C |
| 2026-07-03 | 86.9°C |
| 2026-07-04 | 90.0°C |
| 2026-07-05 | 82.6°C |
| 2026-07-06 | 81.6°C |
| 2026-07-07 | 85.5°C (the alert night) |

**Methodology for the recheck** (to run once 2–3 nights have passed after
`05:00 UTC` under the new schedule):

```promql
max_over_time(node_hwmon_temp_celsius{group="pve_hosts"}[10m] @ <each 05:00-05:15 UTC timestamp>)
```

or equivalently, a range query over each night's `05:00–05:15 UTC` window, same method
used for the pre-fix baseline table above, for direct comparability.

**Decision rule, stated in advance so this isn't re-litigated after the fact:**

- **If peak temp drops below 80°C** across the recheck window: cooling work resolved
  it, schedule move was hygiene as intended, close this as `RESOLVED`.
- **If peak temp stays in the 82–90°C range** even after cooling work: Velero's own
  backup load (not the schedule, not `vzdump`) is the real driver, and the fix has to
  be load-side, not schedule-side. Candidates to propose at that point (not proposed
  now — no evidence yet to justify one over another): `--backup-item-operation-timeout`
  or concurrency limits on Velero's `node-agent` DaemonSet, `ionice`/`nice` wrapping
  the kopia filesystem-backup process, or narrowing `defaultVolumesToFsBackup` scope
  (currently every namespace) to only the PVCs that actually need filesystem-level
  backup instead of relying on volume snapshots where available.

**Not proposing a fix in this PR** — no data yet to justify one, and the decision rule
above already commits to what would trigger a load-side fix versus closing this as
resolved by the cooling work. Revisit after 2026-07-10 UTC at the earliest (3 nights
past the first `05:00 UTC` run).

**Effort:** N/A yet — this is a report-only checkpoint, not a fix. Actual effort will
depend entirely on which branch of the decision rule above the data lands on.

---

### REL-055 — Autonomy-readiness task 2: Discord alert coverage gaps, proven live · **RESOLVED** (2026-07-07)

Audit of steady-state alert coverage (ArgoCD Degraded/OutOfSync, pod CrashLoopBackOff,
node/host pressure, cert-manager renewal failure, backup job failure, Renovate's own
failures) found real gaps, and every fix was proven with a real fired alert reaching
Discord, not just config review.

**Gaps found, live:**

- `KubePodCrashLooping` and `KubeJobFailed` (the latter covers Renovate's own CronJob)
  both already exist as upstream kube-prometheus-stack rules, but ship
  `severity: warning` — the existing Alertmanager route only forwarded
  `severity: critical` plus 2 temp alerts. Neither was reaching Discord.
- `KubeNodeNotReady` — same gap: a node actually going NotReady wouldn't have paged.
- **ArgoCD Degraded/OutOfSync had zero alerting, and the obvious fix path was dead on
  arrival:** `argocd-application-controller`'s metrics port (8082) is not actually
  listening, confirmed live via `/proc/net/tcp` inside the pod, even after a clean pod
  restart — Service/Endpoint/container port are all correctly configured, and the
  binary's own `--help` confirms 8082 is its default. Root cause not found; not worth
  blocking this fix on debugging an upstream binary's undocumented behavior.
- **cert-manager**: zero metrics scraping, zero alerting. Renewal failure would only be
  noticed when something started refusing TLS.
- **Velero backup failures**: zero alerting. Velero doesn't run backups as a native
  Kubernetes Job (it's a goroutine inside the velero pod, driven by a `velero.io`
  `Schedule` CRD, confirmed via `kubectl get cronjob -A` showing nothing owned by
  Velero) — the generic `KubeJobFailed` rule could never have caught this regardless of
  its severity-routing gap above.
- `argocd-notifications-cm` existed live with **zero data** — the notifications
  controller has been running for weeks doing nothing, and was never git-tracked at
  all (same orphan-config class as REL-035/042, just silent instead of loud since an
  empty config doesn't fail).

**Fixed:**

1. **ArgoCD** — pivoted off the broken metrics port entirely. Wired ArgoCD's own
   `argocd-notifications-controller` (already running) with a generic `webhook` service
   (not the named `discord` integration, which needs a bot token) pointed at the same
   Discord incoming-webhook URL Alertmanager already uses
   (`secret/alertmanager:discord-webhook-url`) — one webhook URL, two independent
   delivery paths. Triggers: `on-health-degraded`, `on-sync-failed`,
   `on-sync-status-unknown`, subscribed via the `subscriptions:` top-level key (ArgoCD's
   documented default-subscription mechanism — applies to every Application with zero
   per-app or per-AppProject annotations, deliberately avoiding touching the live
   `default` AppProject, which is untracked in git and cluster-wide blast radius if a
   hand-written spec ever drifted under selfHeal+prune).
   - Found and fixed a real bug in the first draft live: `on-sync-failed`'s expression
     (`app.status.operationState.phase in [...]`) threw `cannot fetch phase from <nil>`
     for every app whose `operationState` was nil (i.e. most apps, most of the time) —
     fixed with a nil guard (`app.status.operationState != nil && ...`).
   - `argocd-notifications-cm.yml` and a new `notifications-external-secret.yml`
     (Merge-policy ExternalSecret for the webhook URL) added to git and to
     `manifests-application.yml`'s include glob — the same explicit, non-wildcard glob
     pattern this repo already uses for `kubernetes/system/*`, so this doesn't repeat
     the REL-014/035/042 "committed but never synced" bug class.
2. **cert-manager** — new `ServiceMonitor` (port `tcp-prometheus-servicemonitor`,
   confirmed matches the live Service) + `PrometheusRule`: `CertManagerCertNotReady`
   (severity critical, direct renewal-failure signal — cert stuck non-Ready 30m+) and
   `CertManagerCertExpirySoon` (severity warning, <7 days to expiry as an early-warning
   companion).
3. **Velero** — new `ServiceMonitor` (port `http-monitoring`, confirmed the live Service
   responds with real `velero_backup_*` series) + `PrometheusRule`: `VeleroBackupFailed`
   (severity critical) and `VeleroBackupPartialFailure` (severity warning).
4. **Alertmanager routing** — added one new route to `alertmanager-config.yml` matching
   `alertname =~ "KubePodCrashLooping|KubeJobFailed|KubeNodeNotReady|
   CertManagerCertExpirySoon|VeleroBackupPartialFailure"` explicitly, rather than
   routing all `severity=warning` (which would also forward routine noise like
   `KubeMemoryQuotaOvercommit`). `CertManagerCertNotReady` and `VeleroBackupFailed` are
   `severity: critical` and need no new routing — they already flow through the
   existing critical route.

**Proved live, both delivery paths, not just config review:**

- Fired a real synthetic `KubePodCrashLooping` alert directly at Alertmanager's API
  (`POST /api/v2/alerts`, executed from inside the Alertmanager pod itself — its API
  binds to `127.0.0.1` only by design, confirmed via `/proc/net/tcp`, connection
  refused from any other pod is expected, not a bug). Confirmed via
  `alertmanager_notifications_total{integration="discord"}` incrementing (11 sent, 0
  failed) and user-confirmed landing in Discord.
- Created a real throwaway `Application` (`synthetic-test-task2-proof`) pointed at a
  nonexistent repo path — genuinely triggered `sync.status: Unknown` (not simulated),
  confirmed `on-sync-status-unknown` `TRIGGERED` in the notifications-controller logs
  and a real send to Discord, user-confirmed landing. Deleted afterward.
- **Live-testing gotcha hit again** (same class as the REL-042 lesson already in
  memory): ArgoCD's `selfHeal` reverted my live-applied test edits back to git's
  (unmodified) state within seconds of each `kubectl apply`, because git didn't have
  these changes yet. Temporarily set `syncPolicy.automated: null` on both
  `monitoring-manifests` and `argocd-manifests` for the duration of live testing,
  restored `{prune: true, selfHeal: true}` on both immediately after — confirmed both
  back to `Synced`/`Healthy` with zero drift before moving on.
- **Also broke and immediately fixed ArgoCD's own `application-controller` mid-diagnosis**:
  a `kubectl patch --type=json` meant to test an explicit `--metrics-port=8082` flag
  replaced the container's `args` entirely (`command` was empty; the actual binary
  invocation lived in `args`), crash-looping the controller for about 2 minutes.
  Reverted immediately, force-recreated the pod, confirmed `1/1 Running`, 0 restarts,
  reconciling normally, before continuing.

**Not fixed, flagged instead:**

- ArgoCD's own metrics port being unreachable remains unexplained. The notifications
  path above makes it non-blocking for this task, but it means ArgoCD's health/sync
  state still isn't visible to Prometheus/Grafana at all — worth a dedicated look, not
  bundled into this PR.
- cert-manager pod has 137 restarts over 14 days (noticed in passing while checking its
  Service) — not chased down, flagged for a separate look.

**Effort:** Medium — mostly investigation (finding the ArgoCD metrics gap took the
longest), the fixes themselves are each small, focused manifests.

---

### REL-032 — Media acquisition stack: no autoheal, recurring silent queue jams · **RESOLVED** (2026-07-02)

Two distinct "usenet does nothing" recurrences in 24h (2026-07-01 permission bug, 2026-07-02
Sonarr import jam) both required manual intervention to notice and fix — no automated
recovery existed for either failure class. Root cause of the second: Sonarr's `DetectSample`
step (used during import to distinguish sample/trailer files from real episodes) choked on a
release group's malformed subtitle track, and separately, a whole-season raw Blu-ray `.iso`
disc image was grabbed that can never be imported (no demuxable video stream at the container
level) — both jammed the queue behind them indefinitely with no self-recovery. Found in the
same pass: two stuck `_UNPACK_` folders (Game of Thrones S03/S08, ~40GB) sitting since
2026-06-28, never imported, salvaged by moving files directly into the library and triggering
a Sonarr rescan instead of re-downloading.

**Fixes:**

1. Docker healthchecks added to all 6 media-acq containers (`sonarr`/`radarr`/`bazarr`/
   `sabnzbd`/`nzbhydra2`/`jellyseerr`) plus a `willfarrell/autoheal` sidecar that force-restarts
   any container Docker marks unhealthy — covers "process alive but hung/unresponsive," the
   class `restart: unless-stopped` alone doesn't catch.
2. New Sonarr/Radarr Custom Format "Block Raw Disc/ISO Releases" (regex on `BD25/50/66/100`,
   `COMPLETE.BLURAY`, `BDMV`, `.ISO`, and season-disc naming like `S06.D04`), scored -10000 in
   every quality profile — rejects this release class at grab time instead of downloading
   50+GB of something that can never be imported. Applied via idempotent Ansible tasks
   (`ansible/roles/media_acquisition/tasks/main.yml`), not just live API calls.
3. New queue watchdog (`ansible/roles/media_acquisition/templates/queue-watchdog.sh.j2`), cron
   every 10 minutes: auto-clears (blocklist + remove) any Sonarr/Radarr queue item stuck in a
   `warning` state for >30 minutes, and posts a Discord notification only when it actually
   clears something (state-change style, no spam on clean runs). Covers the exact failure
   class that caused both this incident and the original REL-020 near-miss — a jammed import
   silently blocks everything behind it while RSS sync keeps running underneath, so nothing
   *looks* broken until someone checks the queue specifically.

Deliberately does **not** attempt to auto-recover SABnzbd itself for connectivity failures
(DNS/ISP outages) — SABnzbd's own retry logic already handles that correctly on its own (see
the 2026-07-02 ISP outage in the 2026-07-01/02 sweep memory), the *arr-side import queue is
where jams actually stick.

---

## Summary Table

| ID | Category | Severity | Title |
|---|---|---|---|
| SEC-001 | Security | **RESOLVED** | Hardcoded OIDC secret in Headscale ConfigMap — moved to Vault via ExternalSecret (2026-06-23) |
| SEC-002 | Security | **RESOLVED** | Shared OIDC client secret across 4 services |
| SEC-003 | Security | **RESOLVED** | Placeholder secrets rotated; found and fixed a much bigger bug along the way -- `configmap.yml` set 4 secret fields (jwt/session/storage-key/hmac) as bare literal strings instead of Authelia's file-templating syntax, so the *actual* functional secrets were public path strings, not the random Vault values (2026-06-24) |
| SEC-004 | Security | **RESOLVED** | Cross-service secret reuse (redis/storage/paperless) |
| REL-010 | Reliability | **RESOLVED** | `postgres-authelia` (CNPG) migrated from `nfs-client` to `local-path` via CNPG's declarative hibernation feature; required adding an ownerReference CNPG doesn't document needing (2026-06-24) |
| SEC-005 | Security | **RESOLVED** | All container images now fully semver-pinned — batch 1 (PR #187, 2026-06-27): uptime-kuma, redis, postgres, nextcloud; batch 2 (PR #193, 2026-06-28): valkey, gotenberg, renovate, gitea, vault, home-assistant, open-webui (:main→v0.9.6), alpine. Renovate kubernetes manager active. |
| SEC-006 | Security | **RESOLVED** | Kyverno enforcement policies in Audit mode |
| SEC-007 | Security | **RESOLVED** | Proxmox provider TLS verification enabled -- Proxmox's cert already had an IP SAN for 10.0.10.10, just needed its CA trusted (custom Atlantis image via update-ca-certificates), verified live via a real `atlantis/plan` succeeding with `insecure = false` (2026-07-06) |
| SEC-008 | Security | **RESOLVED** | Atlantis had zero auth + plain-HTTP entrypoint -- added Authelia (webhook path excluded), HTTPS-only (2026-06-23). **Regressed and re-fixed 2026-07-05**: ADR-012's LXC migration deleted the IngressRoute and repointed the Cloudflare Tunnel straight at the LXC, silently re-exposing it fully public -- caught via a requested security review, recreated the pve-final/pbs-final external-host+Authelia pattern (PR #288) |
| SEC-009 | Security | **RESOLVED** | Home Assistant had no auth layer beyond its own login -- added Authelia, same pattern as Jellyfin (2026-06-23) |
| SEC-010 | Security | **PARTIAL** | 545 open Trivy code-scanning alerts, mostly ~20 manifests missing securityContext; suppressed 2 genuinely-justified findings via .trivyignore; hardening pass done in SEC-012 (2026-06-24) |
| SEC-012 | Security | **RESOLVED** | securityContext hardening across ~25 manifests, 215->171 Trivy findings; first attempt broke 9 containers (capabilities.drop/runAsNonRoot assumptions wrong for several images), caught and fixed live within ~15min across 3 follow-up PRs (2026-06-24) |
| SEC-013 | Security | **RESOLVED** | `.gitleaks-baseline.json` silently suppressed 2 still-live secrets in a public repo -- Garage `rpc_secret`/`admin_token` (S3 backend for Terraform state/Velero/Immich) were byte-identical to their 2026-06-03 git-history values, never rotated. Rotated via Vault + forced ExternalSecret sync + Garage restart, verified healthy live (2026-07-06) |
| SEC-014 | Security | **RESOLVED** | Authelia's `users_database.yml` (real admin password argon2 hash) was a plain committed Secret in a public repo, same class as SEC-001/SEC-003 -- migrated to Vault via ExternalSecret, then the password itself rotated (new hash generated live in-pod, never committed) with the user's explicit sign-off given the SSO blast radius (2026-07-06) |
| SEC-015 | Security | **RESOLVED** | `network/scripts/bootstrap.rsc` had the router's `terraform` API user's real, live password hardcoded in plaintext since 2026-03 -- missed by the gitleaks baseline sweep entirely (not a pattern gitleaks matched). User rotated live via Winbox (the account structurally can't change its own password via API), Vault + Atlantis redeployed to match, hardcoded value scrubbed to a placeholder. Found via a manual portfolio-quality pass, not tooling (2026-07-06) |
| REL-001 | Reliability | **RESOLVED** | All 3 k3s nodes run continuously (`on_boot=true`); single-server topology by deliberate design, not an HA gap -- see `docs/k3s-architecture.md` |
| REL-002 | Reliability | **RESOLVED** | PBS running with `onboot=1`; `all: 1` backup job covers every VM/CT incl. k3s nodes + NFS LXC; verified successful 2026-06-23 03:00 run |
| REL-003 | Reliability | **HIGH** | Velero backend (Garage) is in-cluster; circular recovery dependency |
| REL-004 | Reliability | **HIGH** | NFS single point of failure for all PVCs |
| REL-005 | Reliability | **RESOLVED** | rpool at 70% utilization with no alert -- this is what eventually caused REL-019; Garage's data migrated off rpool (now 60%), capacity alerting added (2026-06-25) |
| REL-006 | Reliability | **HIGH** | No Proxmox VM snapshots for k3s nodes |
| REL-007 | Reliability | **RESOLVED** | Vault seal gap causes cascading ExternalSecret failures on restart — mitigated via faster unseal polling + wait-for-secret initContainers |
| REL-009 | Reliability | **RESOLVED** | Vault's raft storage migrated from `nfs-client` to `local-path` (same BoltDB-on-NFS risk as GIT-006), zero downtime to ExternalSecrets cluster-wide, verified byte-identical data at every copy step (2026-06-24) |
| REL-011 | Reliability | **RESOLVED** | `postgres-authelia` (CNPG) had barman WAL archiving configured but no `ScheduledBackup` resource — no base backup existed to restore from via barman alone, only the PVC itself (Velero/PBS). Added `ScheduledBackup` (`kubernetes/system/postgres/scheduled-backup.yml`), daily `0 2 * * *`, targeting the existing `barmanObjectStore` already on the Cluster; also fixed the `postgres-cluster` Application's `directory.include` glob so the new file is picked up by ArgoCD |
| REL-012 | Reliability | **PARTIAL, likely improved** | k3s control plane (etcd) crash-looping, etcd apply latency up to 14.3s under disk I/O contention; alerting added 2026-06-24. After REL-019's Garage migration freed rpool from 96-100% to 60%, hourly "apply request took too long" counts dropped 1608->337->23->2 tracking the migration timeline -- not yet marked RESOLVED (one prior false-calm window already on record), revisit after a full day clean (2026-06-25) |
| REL-013 | Reliability | **RESOLVED** | Uptime Kuma (23 monitors @ 60s) and Prometheus blackbox-exporter (9 targets @ 30s) both probing largely the same domains, doubled again by a `search home.lan` DNS suffix -- bumped both intervals (2026-06-24) |
| REL-014 | Reliability | **RESOLVED** | Every custom PrometheusRule (SLO alerts, hardware-temp alerts) was silently never evaluated -- missing `release: kube-prometheus-stack` label never matched Prometheus's ruleSelector. Fixed, verified live via /api/v1/rules (2026-06-24) |
| REL-015 | Reliability | **RESOLVED** | Discord alerting silently broken -- Prometheus Operator can't validate `webhook_url_file` in raw Helm config, generated secret was 24 days stale. Manual stopgap restored delivery 2026-06-24; durable fix (AlertmanagerConfig CRD) landed and verified end-to-end via REL-042 (2026-07-05) |
| REL-016 | Reliability | **PARTIAL** | `mini` froze solid during an Ollama CPU inference test (18GB model, likely disk-contention cascade per REL-005/REL-012), needed a manual power-cycle; 5 LXCs had `onboot=0` and didn't auto-recover. Capped AI LXC CPU (6 cores + manual cpulimit, bpg/proxmox has no `limit` attribute), set onboot=1 manually (provider doesn't read this attribute back either). Root disk contention still unresolved (2026-06-24) |
| REL-017 | Reliability | **RESOLVED** | `mc-server-2` (Minecraft, port 25565) had no DNAT rule at all on the live router -- only the forward-filter ALLOW rule existed, never the actual NAT rewrite. Confirmed via the router's own REST API, fixed, verified with a real protocol-level handshake against the public IP (2026-06-24) |
| REL-018 | Reliability/Security | **RESOLVED** | `kubernetes/system/*.yml` had zero ArgoCD tracking -- `kubectl apply` couldn't prune removed resources. Found a live regression in the gap: a duplicate, unrestricted `traefik-dashboard` IngressRoute was periodically overwriting the correct path-restricted one via selfHeal. Added `system-manifests` Application, removed the duplicates (2026-06-24, #124) |
| REL-019 | Reliability | **RESOLVED** | `rpool` hit hard ENOSPC, pausing all three k3s VMs (`qm status: io-error`) -- root cause was Velero's `daily-backup` (30-day TTL, `defaultVolumesToFsBackup: true`) backing up Garage's own data volume into Garage's own S3 backend nightly, an unbounded circular write. Excluded Garage's volumes from FS backup, paused the schedule pending verification, fixed `pve-exporter`'s never-completed auth token (had shipped with a plaintext `REPLACE_WITH_TOKEN_VALUE` placeholder, 401 since deployment), added ZFS capacity alerting (2026-06-25) |
| REL-020 | Reliability | **RESOLVED** | Radarr's database hit a transient NFS I/O error on restart (no liveness probe, so Kubernetes reported it healthy while actually down) -- `integrity_check` came back clean, a WAL checkpoint fixed it with zero data loss. Surfaced that `sonarr/radarr/bazarr/sabnzbd-config` were on `nfs-client`, the same storage class documented unsafe for SQLite -- closed out 2026-07-06: the WRK-006 cutover completed, these apps no longer run in k8s at all (config lives on the media-acq LXC's local ZFS storage, zero NFS involvement), so the underlying risk no longer exists (2026-06-25 / 2026-07-06) |
| REL-021 | Reliability/Security | **PARTIAL** | Authelia's readOnlyRootFilesystem (SEC-012) passed a live test, then crash-looped in production hours later (35+ restarts, generic fatal error, no detail) -- a live outage on home.woitzik.dev. Reverted; root cause of the intermittent failure still unknown. Also found and fixed a related but separate SEC-012 regression on homepage (EROFS creating docker.yaml) in the same response (2026-06-25) |
| REL-022 | Reliability/Security | **RESOLVED** | Third SEC-012 readOnlyRootFilesystem regression, same class as REL-021: open-webui's static branding assets (favicons, splash, loader.js) failed to write under EROFS on every boot. Fixed with an init container that copies the existing static dir into an emptyDir before overlaying it, preserving required assets (fonts/, swagger-ui/) that a bare emptyDir would have wiped (2026-06-25) |
| REL-023 | Reliability | **PARTIAL** | Garage logging recurring "Unable to decode entry of object" -- traced to 8 corrupted Velero/kopia backup chunks for nfs-provisioner-root and two apps PVs, likely from the REL-019 disk-full window. No live data affected, but a fresh ad-hoc backup reproduced a real, repeatable failure backing up nfs-provisioner-root specifically. Root cause of that cancellation not yet found (2026-06-25) |
| REL-008 | Reliability | **LOW, accepted risk** | uptime-kuma's local-path storage is actually correct (it's SQLite-backed, NFS would reintroduce GIT-006); already covered nightly by the existing Velero daily-backup, original "migrate to NFS" fix suggestion was wrong (re-checked 2026-07-06) |
| GIT-001 | GitOps | **HIGH** | TF state backend requires live in-cluster Garage |
| GIT-002 | GitOps | **RESOLVED** | k3s-12/13 mistakenly retagged "master"/control-plane; reverted to "worker" (agent-only) — single-etcd design confirmed correct (2026-06-23) |
| GIT-006 | GitOps | **RESOLVED** | Garage `garage-meta` (sqlite) was on NFS (`nfs-client`); SQLite's locking/WAL model is incompatible with NFS and the metadata DB became corrupted ("database disk image is malformed" / "locking protocol" errors), breaking Velero, Loki, and TF-state writes. Recovered via `sqlite3 .recover` + cleared derived merkle/GC tables; fixed by migrating `garage-meta` to `local-path` (2026-06-23). `garage-data` (blob storage, no locking needs) remains on NFS, which is fine. Audited every other app on `nfs-client` for the same risk and found 6 more SQLite-backed apps exposed: Headscale (migrated same day, PR #50), Vaultwarden, Gitea, Mealie, Open WebUI, paperless-ai, and Home Assistant — all migrated to `local-path` 2026-06-23, each backed up and `PRAGMA integrity_check`-verified before and after. None had corrupted yet, but Vaultwarden/Open WebUI/Home Assistant were confirmed in WAL mode (the highest-risk configuration, same as Garage). |
| GIT-007 | GitOps | **RESOLVED** | `network/terraform.tfstate` did not exist in Garage at all (only `proxmox/terraform.tfstate` was present) — likely lost during the 2026-06-14 Garage/Longhorn-OOM corruption and never reconciled. Rebuilt 2026-06-23 via a full resource-by-resource `terraform import` against the live router (matched ~110 resources via REST API dumps), validated against a local scratch state with zero `terraform plan` diff before ever touching the real backend. Found and fixed along the way: (1) 15 firewall-filter resources already under `import {}` would have been destroy+recreated on apply — `place_before` has no live-readable value and was being treated as a replace-triggering field on resources that already exist correctly positioned; added `lifecycle { ignore_changes = [place_before] }` to all of them. (2) The 4 `routeros_ip_service` resources (telnet/ftp/api/api-ssl) can't use `import {}` blocks at all — a provider bug (terraform-routeros 1.99.1, latest) makes the post-import Read always fail for name-keyed resources; left them as plain resources instead, since their create function safely PATCHes the existing built-in service by name rather than creating a duplicate. (3) `fwd_12_wan_to_cobblemon` (`nat_portforward.tf`) was a byte-identical duplicate of the already-imported `fwd_wan_cobblemon` (`firewall_extra.tf`) — same live rule claimed under two Terraform addresses; removed the duplicate. |
| GIT-008 | GitOps | **RESOLVED** | Live duplicate: `routeros_ip_firewall_mangle.mss_clamp` existed twice on the router (ids `*1` and `*5`), byte-identical config, both carrying real traffic — almost certainly created by a prior `apply` retried against the same missing state (GIT-007). Fixed in two real Terraform applies (not a manual RouterOS edit): imported `*5` as `mss_clamp_duplicate` (PR #279), then converted it to a `removed { lifecycle { destroy = true } }` block and applied the destroy (PR #285). Along the way, root-caused a mysterious recurring "Resource has no configuration" Terraform bug that had blocked the whole network stack for weeks (see REL-047) (2026-07-05). |
| GIT-009 | GitOps | **RESOLVED** | Two NAT masquerade rules (outbound WAN `*5`, MGMT->SRV `*8`) brought under Terraform via import; also found and fixed a dangling interface-list reference on `*5` (2026-06-24, needs `atlantis apply` to land) |
| GIT-010 | GitOps | **RESOLVED** | `postgres-cluster` Application's directory glob never matched its ExternalSecret filename -- silently unmanaged by GitOps since creation, fixed (2026-06-24) |
| GIT-011 | GitOps | **RESOLVED** | Two LXC-creation blockers found provisioning WRK-006: Atlantis's TF token isn't root@pam (blocks device_passthrough on create), and `usb-templates`' Proxmox storage registration was missing (disk was fine, re-registered) (2026-06-24) |
| GIT-003 | GitOps | **HIGH** | System components are manual-apply; no drift detection -- confirmed this silently broke both GIT-010 and REL-011's fixes until caught manually (2026-06-24) |
| GIT-004 | GitOps | **RESOLVED** | Proxmox provider constraint was far behind at first audit; already bumped to `~> 0.111` (latest available, `0.111.1`) by Renovate across several since-merged PRs -- just never marked resolved (2026-07-06) |
| GIT-005 | GitOps | **DEFERRED** | Offsite backup (R2/B2) deliberately skipped -- neither provider offers a true no-cost guarantee that fits the "never pay" requirement without tradeoffs (2026-06-24) |
| IAC-001 | IaC | **RESOLVED** | ~50% of app Deployments lack resource limits |
| IAC-002 | IaC | **RESOLVED** | MikroTik firewall hardening apply blocked on Atlantis's k3s-hosted availability -- superseded by ADR-012 (Atlantis moved to its own LXC), network stack applies cleanly now (re-checked 2026-07-06) |
| IAC-003 | IaC | **LOW** | No automated k3s VM rebuild procedure |
| IAC-005 | IaC | **RESOLVED** | Cleanup batch from the STATUS.md re-assessment: removed dead `minio` container (ct-srv-docker-01, unused since April, snapshotted first), deleted 4 confirmed-merged remote branches + 8 local (the initial ~74 estimate was inflated by stale local refs a `git fetch --prune` cleared), corrected 2 stale doc claims (pending-major-upgrades.md, REL-015), marked GIT-004 resolved (2026-07-06) |
| DOC-001 | Docs | **RESOLVED** | DISASTER-RECOVERY.md does not exist -- added at repo root covering all 6 required tiers + per-service restore table (2026-06-23); this summary row was stale, the detailed entry already said RESOLVED |
| DOC-002 | Docs | **RESOLVED** | ROADMAP.md already fully English -- stale finding, translated at some point but never marked resolved (re-checked 2026-07-06) |
| DOC-003 | Docs | **RESOLVED** | compute-nodes.md has stale ingress description |
| DOC-004 | Docs | **RESOLVED** | 4 architectural decisions without ADRs — added ADR-006..009; ADR-011 (Cloudflare Tunnel external access) added 2026-06-27 |
| DOC-005 | Docs | **RESOLVED** | `docker/crafty`/`docker/npmplus` described services not actually running -- first-pass fix (new static reference copies) was itself wrong, corrected same-day: these are already real Ansible-managed roles (`minecraft`/`nginx_proxy_manager`/`crowdsec_bouncer`/`watchtower`/`monitoring_agent`), `docker/` removed entirely. Also found and fixed a genuine live drift: Ansible's minecraft role still referenced the stale `data-2` world while the live container actually runs on `data-3` -- would have reverted the live world on next playbook run (2026-07-06) |
| DOC-006 | Docs | **RESOLVED** | Two conflicting Renovate configs at repo root (`renovate.json` + `renovate.json5`) -- confirmed the `.json5` was never actually read (Renovate only uses the first config file it finds), removed it, no functional change (2026-07-06) |
| WRK-001 | Workloads | **RESOLVED** | Jellyfin/media stack stuck in ContainerCreating — resolved via WRK-006 (media acq → LXC) and WRK-007 (Jellyfin → LXC) |
| WRK-002 | Workloads | **LOW** | Minecraft not GitOps-managed; playit.gg agent install not Ansible-ized (re-checked 2026-07-06: backup coverage is fine, nightly PBS `all:1` job already covers it, and whitelist already active on all 4 servers -- prior "no backup/no whitelist" assumptions were wrong) |
| WRK-003 | Workloads | **RESOLVED** | Paperless fails on cluster restart due to Vault seal gap |
| WRK-004 | Workloads | **RESOLVED** | paperless-gpt failing on every document; Ollama iGPU (Vulkan) crashing constantly under load -- switched to CPU-only |
| WRK-005 | Workloads | **PARTIAL** | Paperless data-quality pass: missing archives (nfs-client related, fixed) + 5 "hallucinated" docs were actually scanned upside-down (fixed) + LLM_MODEL occasionally returns chatty-assistant text instead of short field values (low-frequency, not fixed) (2026-06-24) |
| WRK-006 | Workloads | **RESOLVED** | Media acquisition stack moved to a dedicated LXC (ADR-010). The gluetun/Mullvad half was never finished and isn't needed -- re-verified 2026-07-06: SABnzbd connects directly to Eweka over SSL/NNTPS (already fully encrypted, no VPN benefit), Tor SOCKS5 stays for its original purpose (NZBHydra2 indexer-query IP protection, fail-closed, live-confirmed in nzbhydra.yml). Verified correct as designed, not incomplete -- see ADR-013 |
| WRK-007 | Workloads | **RESOLVED** | Jellyfin moved to a dedicated GPU-passthrough LXC for VAAPI hardware transcode (shares mini's APU render node with ct-srv-ai-01's ROCm passthrough); config migrated and verified, old k8s resources removed (2026-06-24) |
| WRK-008 | Workloads | **LOW** | Offsite backup to Cloudflare R2 (`kubernetes/system/velero/offsite-schedule.yml`/`r2-backuplocation.yml`) was scaffolded but never finished -- `r2-backuplocation.yml` has a literal `ACCOUNT_ID` placeholder and its referenced credential secret (`velero-r2-credentials`) doesn't exist anywhere (not Ansible Vault, not HashiCorp Vault). Confirmed not actively broken (Velero/ArgoCD just silently never create the BackupStorageLocation/Schedule, no error state) -- local backups to Garage/archive pool work fine. User decided to leave it deferred rather than complete or remove it now (2026-06-25) |
| WRK-009 | Workloads | **RESOLVED** | Immich stuck on v1.109.2 with no external access — fresh install v2.7.5 (VectorChord postgres, Valkey, port 2283), Cloudflare Tunnel for `photos.woitzik.dev` (2026-06-27). Since bumped: postgres 14->16 (REL-030, 2026-07-05), server/ML v2.7.5->v3.0.1 (REL-053, 2026-07-06) |
| REL-024 | Reliability | **RESOLVED** | Valkey RDB persistence blocked all writes with readOnlyRootFilesystem — disabled RDB+AOF (in-memory only, appropriate for cache/queue workload) (2026-06-28) |
| REL-025 | Reliability | **RESOLVED** | immich-ml HuggingFace xet downloader wrote temp files to read-only root FS — redirected via HF_HOME+XDG_CACHE_HOME to writable PVC (2026-06-28) |
| REL-026 | Reliability | **RESOLVED** | Immich uploads via Cloudflare Tunnel failing with ECONNRESET for large files — Cloudflare buffers entire multipart body without chunked encoding. Fixed: `chunked_encoding = true`, `write_timeout = 600s`, `read_timeout = 120s` in tunnel origin_request (PR #192, 2026-06-28) |
| GIT-012 | GitOps | **RESOLVED** | Cloudflare Terraform provider v4 → v5 breaking changes: `cloudflare_tunnel_config` → `cloudflare_zero_trust_tunnel_cloudflared_config`, `cloudflare_record` → `cloudflare_dns_record`, `value` → `content`. Migrated with `moved {}` blocks to prevent destroy+recreate of live tunnel + DNS record. Provider `~> 4.0` → `~> 5.0` (PR #192, 2026-06-28) |
| REL-027 | Reliability | **RESOLVED** | Vault unseal-helper CLI major bump 1.21.4→2.0.3 (Renovate #204) -- found already merged 2026-07-04 but never marked resolved; verified live 2026-07-06 by force-restarting vault-0 and confirming the unseal script actually completes ("Unseal attempt done" in its logs) and `Sealed: false`, not just that the pod is Running |
| REL-028 | Reliability | **RESOLVED** | Postgres for Nextcloud + Paperless major bump 16.14→18.4 (PR #255, #257) — executed via pg_dump/restore into fresh PVCs, not a bare image swap. Found live: PG18 requires a single `/var/lib/postgresql` mount (not the old data+subPath convention), and Nextcloud's `config.php` used a different DB role (`oc_dw`) than `POSTGRES_USER` -- both fixed, both apps verified reachable (2026-07-04) |
| REL-029 | Reliability | **RESOLVED** | Nextcloud app major bump 30.0.17→34.0.1 — ran all 4 sequential `occ upgrade` passes (30→31→32→33→34). Found live: image entrypoint needs CAP_SETGID (`su`) during the upgrade to rsync app files, temporarily un-hardened then re-hardened after; `occ upgrade` must wait for the entrypoint's own background file-sync to finish first. Verified reachable + user data intact (2026-07-05) |
| REL-030 | Reliability | **RESOLVED** | Immich Postgres (VectorChord) major bump 14→16 (PR #267) — largest PVC in cluster, executed via `pg_dumpall`/restore into fresh PVC. Verified: vchord/vector extensions loaded, asset/asset_face row counts match pre-migration, photos.woitzik.dev + API ping working. All 4 deferred Renovate majors (REL-027/028/029/030) now done (2026-07-05) |
| REL-039 | Reliability | **RESOLVED** | Live Nextcloud outage — `redis-nextcloud` (no PVC) ran with default RDB persistence, silently failed writing to the read-only rootfs until `stop-writes-on-bgsave-error` tripped and blocked ALL writes including PHP sessions, hanging every request. `redis-paperless` had the identical latent bug, fixed proactively. Both switched to `redis-server --save "" --appendonly no` (matches immich-redis/valkey). Also found/fixed along the way: re-hardening nextcloud's `capabilities: drop: ["ALL"]` after REL-029 broke Apache's worker processes permanently, not just during the upgrade — reverted (2026-07-05) |
| REL-032 | Reliability | **RESOLVED** | Media acquisition stack had no autoheal — two "usenet does nothing" recurrences in 24h needed manual fixes. Added docker healthchecks + `autoheal` sidecar (restarts hung-but-alive containers), a "Block Raw Disc/ISO Releases" Custom Format (-10000 score, rejects un-importable raw disc rips at grab time), and a 10-min cron queue watchdog that auto-blocklists Sonarr/Radarr items stuck >30min in a warning state, with Discord notification only on actual action (2026-07-02) |
| REL-031 | Reliability | **RESOLVED** | `ct_dmz_games_01` (Minecraft) cpu.cores 4→2 — first cut into the host overcommit ratio; folded into REL-035 below (2026-07-04) |
| REL-035 | Reliability | **PARTIAL** | Host `mini` (8C/16T, 62GB) runs ~34 vCPU / ~91GB allocated across all VMs/CTs — a chronic ~2.1x CPU / ~1.5x memory overcommit that has caused repeated, recurring incidents (REL-012c etcd fdatasync stalls, the REL-016 Ollama host-freeze, and a 2026-07-04 cascade where a single test pod pushed host load 1.49→18.9 and briefly crash-looped k3s). Each prior incident was patched individually without addressing the shared root cause. Fixed this pass: (1) all 3 k3s VMs get `cpu.units = 2048` (2x the Proxmox default) so etcd/kubelet win CPU scheduling contention against every LXC on the host instead of competing on equal footing; (2) `ct_srv_ai_01` (Ollama, REL-016) now sets `cpu.limit = 6` directly in Terraform — the previous fix relied on a manual `pct set 201 -cpulimit 6` that was documented as done but confirmed **not actually present** on the live host on 2026-07-04 (bpg/proxmox 0.100.0 had no `limit` attribute; 0.111.0 does), meaning that container had had zero effective CPU ceiling since whenever it was last recreated; (3) `ct_dmz_games_01` (REL-031) memory reservation cut 16GB→8GB (observed peak usage ~4.7GB) to claw back the largest unused-but-allocated chunk after ai-01's 32GB. **Still open:** total allocation is still >16 threads / >62GB even after this pass (hardware is fixed, single-host by design per CLAUDE.local.md) — the units/limit weighting makes contention *survivable* for etcd, it doesn't remove contention. No CI/lint gate yet stops total allocation from creeping back up via future Renovate/feature additions; a documented per-host allocation ceiling + pre-commit check is the logical next step if this recurs again (2026-07-04) |
| REL-035b | Reliability | **RESOLVED** | First-cut guard summed VM+LXC `dedicated` together against one 50GB ceiling -- wrong, conflates VM host-reserved memory with LXC soft cgroup ceilings; also mischaracterized `ct_dmz_games_01` as a fresh trim candidate when it was already REL-035's own trim result. Reworked to two tiers: hard gate (VM `dedicated` sum 28GB + ARC 4GB + host reserve 6GB = 38GB vs. 44GB ceiling, fails CI, still names REL-016) + soft warn-only check (LXC `dedicated` sum 57GB vs. 62GB physical RAM, never fails). Live `free -h` (41/62GB used) confirmed the host isn't actually oversubscribed -- the old "35GB overage" was almost entirely soft CT limits, not real pressure. `ai-01`'s 32GB and all VM values untouched (2026-07-07) |
| REL-036 | Reliability | **RESOLVED** | Atlantis ran as a k8s Deployment scheduled on vm-srv-k3s-11/12 -- the same VMs it applies Terraform changes to. Twice on 2026-07-04, a plan that changed one of those VMs' config (bpg/proxmox implements `cpu.units`/`serial_device` changes as a real `qmshutdown`+`qmstart`, not a live update) shut down the very node Atlantis was running on mid-apply, confirmed via the Proxmox task log (`qmshutdown 211 terraform@pve` at the exact interrupt timestamp) and k8s events (`SandboxChanged` on the atlantis pod same second). Fixed via ADR-012: moved Atlantis to its own dedicated LXC (`ct-srv-atlantis-01`, 10.0.20.250), fully decoupling its availability from the infrastructure it manages. Cutover verified live (new instance received a GitHub webhook and completed a real `terraform apply` post-migration). k8s-side resources (Deployment/Service/ConfigMap/PVC, the REL-034 `allow-atlantis-ingress` NetworkPolicy exception, the vestigial Traefik IngressRoute) removed in the same change. |
| REL-037 | Reliability | **RESOLVED** | REL-035 (`cpu.units`) only addressed CPU scheduling contention -- the recurring REL-012c "leader is overloaded likely from slow disk" etcd crash signature is disk I/O contention on `mini`'s single shared SSD. `zfs_vdev_async_write_max_active` defaulted to 10, equal to `zfs_vdev_sync_write_max_active` (also 10), so any LXC/VM's bulk async writes competed for ZFS's per-vdev queue on equal footing with etcd's own synchronous WAL fdatasync. Capped async to 3, well below sync's ceiling, applied live + brought the previously-manual `/etc/modprobe.d/zfs.conf` under `ansible/roles/pve_power/` (2026-07-04). Investigated and ruled out per-container disk I/O throttling (`mbps_rd`/`mbps_wr`) as an alternative -- not possible on Proxmox 9.2 for LXCs at all, confirmed via `pct set` rejection + `man pct.conf` (QEMU VM-disk-only feature). |
| REL-038 | Reliability | **RESOLVED** | All 3 Terraform stacks' S3 backend hardcoded `http://garage.apps.svc.cluster.local:3900` -- a k8s-internal Service DNS name. After ADR-012 moved Atlantis onto its own LXC, `terraform init` failed outright (DNS lookup failure) for every stack -- silently broken since the migration, not caught immediately because applies run right after cutover happened to land on the old k8s instance before the tunnel fully switched over. Repointed to `https://s3.woitzik.dev` (same as Atlantis's own `AWS_ENDPOINT_URL_S3` env var; AdGuard split-horizon DNS resolves it to Traefik's internal LB for LAN clients) (2026-07-04). |
| UX-001 | UX | **RESOLVED** | `requests.woitzik.dev` (Jellyseerr) sat behind both Authelia forward-auth AND its own per-user login, prompting twice for unrelated credentials -- unlike PVE/PBS/ArgoCD/Grafana/Headscale, Jellyseerr 2.7.3 has no OIDC client support (confirmed via container code search) so the Authelia session could never be reused to skip the second prompt. Sonarr/Radarr/NZBHydra2 already run `AuthenticationMethod: None`/`authType: NONE` (single Authelia-only gate); Jellyfin itself has no Authelia gate at all for the same reason. Removed the Authelia middleware from Jellyseerr's IngressRoute to match the Jellyfin precedent -- native per-user login (needed for per-user request permissions) remains the sole gate (2026-07-05). |
| REL-040 | Reliability | **RESOLVED** | `postgres-authelia-backup` (CNPG ScheduledBackup, added in REL-011) had been stuck since 2026-06-25: its `status.nextScheduleTime` froze at a single stale timestamp after a transient "pod does not exist" failure, and the operator's reconciler kept retrying the exact same (already-existing) `Backup` object name forever -- confirmed via a stuck event recurring 90 times over ~20h (`kubectl get events`, reason `BackupCreation`, "already exists"). This meant **zero successful scheduled Authelia DB backups for ~10 days** (only WAL archiving continued). The same endless-retry spin is also the likely cause of the CNPG operator pod's 284 restarts over 17 days (exit 255, no panic/OOM in logs -- consistent with liveness-probe kills from a reconciler stuck busy-looping). Fixed by deleting the stuck `ScheduledBackup` CR and letting ArgoCD self-heal recreate it with a clean status; verified live -- next backup fired immediately, completed successfully, and correctly scheduled the following run (2026-07-05). Operator restart count should be monitored going forward to confirm it stops climbing now that the reconcile-storm is gone. |
| REL-041 | Reliability | **RESOLVED** | Homepage logged an EROFS warning at every pod start -- Next.js tries to write its ISR prerender output under `/app/.next` (`Failed to update prerender cache for /en ... open '/app/.next/server/pages/en.html'`), which fails under `readOnlyRootFilesystem`. Cosmetic (app served fine regardless, just skipped caching that one page), same class as the existing SEC-012 fixes in this file. Fixed the same way as open-webui's static-assets fix: `/app/.next` also holds the compiled server bundle the app needs to run, so a bare `emptyDir` would have wiped it -- added a `copy-next` initContainer to seed a writable copy first, then mounted that over `/app/.next` (2026-07-05). |
| REL-042 | Reliability | **RESOLVED** | Discord alerting (REL-015) had been completely dead for 8+ days despite a real fix already merged to git on 2026-06-27 -- root cause was two-layer: (1) `kubernetes/system/monitoring/application.yml` and `manifests-application.yml` (the Application object defining the whole kube-prometheus-stack Helm release, and the Application managing this directory itself) were BOTH missing from `monitoring-manifests`'s `directory.include` glob, so neither file was ever re-synced by ArgoCD after its initial one-time manual bootstrap -- any edit to either was silently a no-op live, confirmed via the live Alertmanager CR still pointing `configSecret` at a Secret (`alertmanager-discord-config`) that didn't even exist, weeks after that exact line was removed from git. (2) Once manually `kubectl apply`'d to sync live state with git, the intended fix (an `AlertmanagerConfig` CRD referenced cross-object from the main route as `monitoring/alertmanager-config/discord`) still failed with "undefined receiver ... used in route" -- the AlertmanagerConfig object had a `receivers` list but no `route` section of its own, and per upstream prometheus-operator maintainers, AlertmanagerConfig objects must be fully self-contained; a receiver is only exposed for cross-reference if it's reachable via that object's own route tree. Fixed by giving `alertmanager-config.yml` its own complete route (null-receiver default + 2 child routes for hardware-temp/severity-critical -> discord) and setting `alertmanagerConfigMatcherStrategy: OnNamespaceExceptForAlertmanagerNamespace` on the Alertmanager CR so the operator doesn't auto-scope it to `namespace=monitoring` only. Added both previously-orphaned files to the tracking glob so this class of drift can't recur. Verified fully end-to-end: fired a real test alert through the live API, confirmed `alertmanager_notifications_total{integration="discord"}` incremented with 0 failures (2026-07-05). |
| REL-043 | Reliability | **RESOLVED** | Keel logged `"cannot list resource \"daemonsets\""` RBAC errors every ~45s -- its ClusterRole granted deployments/statefulsets/cronjobs but not daemonsets, which Keel's watch loop queries unconditionally regardless of whether any DaemonSet actually carries a `keel.sh/policy` annotation. Added read-only (`get/list/watch`, no `update/patch`) daemonset access -- none of this repo's DaemonSets (node-exporter, promtail, metallb-speaker) are meant to be Keel-managed (2026-07-05). |
| REL-044 | Reliability | **RESOLVED** | **Live outage, found and fixed same-session**: `argo.woitzik.dev`, `monitoring.woitzik.dev` (Grafana), and `status.woitzik.dev` (Uptime Kuma) all returned bare 404 -- confirmed live via `curl`. Root cause: PR #240 (merged 2026-07-04) fixed Traefik's `providers.kubernetescrd.allowCrossNamespace` (every IngressRoute referencing `{name: authelia, namespace: apps}` from outside the `apps` namespace was silently failing) and a large-upload `readTimeout` fix, but the Traefik Application object was never re-synced after merge -- same class of bug as REL-042 (untracked Application-bootstrap file, see below). `vault.woitzik.dev` happened to still work since Vault's IngressRoute lives in `apps` itself. Fixed by manually applying the already-correct git manifest; verified all 3 endpoints return the expected `302` immediately after Traefik's rollout completed (2026-07-05). |
| REL-045 | Reliability | **RESOLVED** | Velero's kopia repository-maintenance-frequency fix (merged 2026-07-01, intended to cut hourly kopia jobs on 11 BackupRepositories down to daily -- see REL-023/the 22 stale Failed jobs cleaned up earlier this session) had **two independent bugs that meant it never took effect**, discovered only after checking the live Velero Deployment's actual container args against git: (1) `extraArgs` was placed at the top level of the Helm values instead of nested under `configuration.extraArgs` -- Helm silently ignores unrecognized top-level keys, matching the chart's own template (`{{ .Values.configuration.extraArgs }}`, confirmed via chart source); (2) even if correctly nested, the flag name itself was `--default-repo-maintenance-frequency`, which doesn't exist -- the real flag is `--default-repo-maintain-frequency` (matches known upstream issues velero/velero#8156 and #8543). Fixed both; confirmed live via `kubectl get deploy -o jsonpath` that the corrected flag now appears in the running container's args (2026-07-05). |
| REL-046 | Reliability | **PARTIAL** | Systematic check (`kubectl diff -f` against every one of the ~21 self-bootstrapped Application manifests across `kubernetes/system/**`, prompted by finding REL-042's tracking gap) found **7 files with live/git drift**, of which 2 were real, previously-invisible bugs (REL-044 Traefik outage, REL-045 Velero maintenance-frequency), 2 were additional untracked-file gaps now manually synced (`postgres-cluster-application.yml`'s `backup-config` glob entry; `infrastructure/application.yml`, harmless), and 1 was caught and deliberately reverted before merging (`velero/manifests-application.yml`'s glob briefly included `offsite-schedule.yml`/`r2-backuplocation.yml` -- WRK-008's intentionally-incomplete R2 offsite feature, which auto-activated into a real but permanently-`Unavailable` BackupStorageLocation and a Schedule that would have failed daily at 4am; deleted both live and re-excluded from the glob to match the existing deliberate-defer decision). **Not fixed**: the other ~14 orphaned Application files (cert-manager, traefik itself, metallb, kyverno, tempo, chaos-mesh, cloudnative-pg, external-secrets, cert-manager-config, metallb-config, nfs-provisioner, vault(+manifests), argocd-manifests) currently show zero drift, but nothing stops the same class of bug recurring the next time any of them is edited -- the systemic fix (one root Application, or an extended ApplicationSet, that recursively tracks every `kind: Application` manifest under `kubernetes/system/**`) is scoped out for a dedicated future session rather than touching every Application in the cluster at once here. |
| REL-047 | Reliability | **RESOLVED** | Root-caused a mysterious, recurring Terraform error ("Resource has no configuration... this is a bug in Terraform; please report it!") that had blocked *any* plan of the whole `terraform/stacks/network` stack for weeks, misdiagnosed in earlier sessions as an unfixable upstream Terraform bug (bug #34992 was cited but never actually located/confirmed). Real cause: `fwd_wan_minecraft`, `fwd_wan_cobblemon`, and `dstnat_cobblemon` each still had a leftover `import {}` block in `imports.tf` from before PR #216 replaced their `resource {}` blocks with `removed {}` blocks -- having both an `import` targeting a resource address and a `removed` block destroying that same address in one plan is what triggered it. `dstnat_minecraft`, which never had a leftover import block, always planned fine, which is what eventually gave this away. Deleted the 3 stale import blocks; the full network stack now plans and applies cleanly with zero workarounds (2026-07-05). |
| REL-048 | Security | **RESOLVED** | The Cloudflare API token used by Atlantis had been completely unable to manage any DNS records since it was first issued (confirmed live: `GET /zones` returned an empty result -- zero zone-level permissions of any kind), blocking IAC-004 (Minecraft playit.gg DNS cutover) and the Jellyfin/Immich/Atlantis tunnel DNS records for over a week. Root cause was permission-scope, not a bug -- required the account owner to grant access. Rotated to a properly-scoped token (Zone: DNS Edit for woitzik.dev + Account: Cloudflare Tunnel Edit, both permission groups on one token, created via a single API call rather than the dashboard UI after two rounds of single-scope tokens failed to combine correctly through the UI) using the account's Global API Key as a one-time bootstrap credential; the two superseded single-scope tokens and the Global Key itself were deleted/rotated immediately after. Deployed to the Atlantis LXC via Ansible; unblocked and completed GIT-008, IAC-004, and the 3 previously-unappliable `cloudflare_dns_record` resources (imported, since all 3 already existed live from earlier dashboard-created records) (2026-07-05). |
| REL-049 | Reliability | **PARTIAL** | Usenet stack effectively dead -- 11/12 NZBHydra2 indexers `DISABLED_USER` incl. paid NZBGeek; re-enabled, but NZBGeek's own membership is expired (external, needs renewal). Separately: Sonarr's language profile hard-filtered non-English releases before custom-format scoring ever ran, silently blocking already-correct German custom formats -- added German as an allowed language (2026-07-05) |
| REL-050 | Reliability | **RESOLVED** | Jellyseerr requests stuck "Processing" forever despite files existing -- the only Radarr server was mismarked `is4k: true`, so non-4k completion status wrote to `status4k` instead of `status`. Fixed the flag; also tightened radarr/sonarr-scan to every 2h, availability-sync to every 3h, Radarr RSS sync 30min->15min (2026-07-05) |
| REL-051 | Reliability | **DEFERRED (deliberate)** | PBS offsite backup to Google Drive's cron job was missing live -- confirmed with the account owner this was an intentional disable (insufficient Drive storage quota), not a bug. Stale Vault rclone token (would've clobbered the working live token) fixed anyway; cron explicitly set `state: absent` to match the real decision instead of silently drifting back to `present`. Also fixed an unrelated idempotency bug (PBS force-restart task ran on every Ansible pass, moved to a handler). Underlying Google Drive API throttling on PBS's many-small-file format (~12-week ETA for a full sync) documented for if this is ever revisited with more storage (2026-07-06) |
| REL-052 | Reliability | **RESOLVED** | First real, live-verified PBS restore test (`ct-srv-atlantis-01` snapshot restored to a scratch vmid, booted, Docker stack came up clean, data intact, test container destroyed) -- `DISASTER-RECOVERY.md`'s restore procedure had never actually been tried before. Found and documented a real gotcha (PBS restore duplicates the original's static IP/MAC, causing a live conflict if started alongside the still-running original) and a bigger doc-accuracy gap (the runbook still pointed at the Google Drive offsite copy as a fallback for total PBS-storage loss, which REL-051 confirms doesn't actually have usable data) (2026-07-06) |
| REL-053 | Reliability | **RESOLVED** | Immich major bump v2.7.5->v3.0.1 (PR #273, the last of the 2026-07 deferred Renovate majors) -- checked upstream breaking changes first (API-only, no DB migration needed since VectorChord already in place per REL-030), took a real pg_dumpall backup, merged, verified live: 0 restarts, identical asset/asset_face row counts (11553/5461), API reports v3.0.1, login page reachable (2026-07-06) |
| REL-054 | Reliability | **RESOLVED** | PR #306's kubeconform rate-limit fix (`-cache` + `actions/cache`) was a mitigation not a fix -- proved live with a broken proxy that a cold-cache/never-seen schema still hard-fails CI on network error (`-ignore-missing-schemas` only catches 404s, not 429s/timeouts). Vendored the 15 built-in-kind schemas actually used under `kubernetes/` into `ci/kubeconform-schemas/`, switched pre-commit + CI to `-schema-location` pointing only at that local dir -- reran the same broken-proxy test, `Errors: 0`, fully offline. CRD kinds (Application/IngressRoute/etc.) still skip via `-ignore-missing-schemas`, unaffected (2026-07-06) |
| REL-057 | Reliability | **PARTIAL** | Autonomy-readiness task 4 (report only): ArgoCD selfHeal PROVEN on for all 41 Applications. cert-manager renewal CONFIGURED but unproven (cert has never actually renewed yet). Backups: schedule proven reliable, but 2 of last 5 daily runs actually FAILED on a Garage S3 timeout (separate from REL-019), and `restores.velero.io` is empty cluster-wide -- Velero-level restore has NEVER been tested (REL-052 tested PBS/hypervisor restore only, a different system). Backup scope includes the `garage` namespace itself, confirming REL-003's circular-dependency risk live (skip-list, not touched) (2026-07-07) |
| REL-058 | Reliability | **PARTIAL** | DNS query volume 40k->1.8M/7d post-K3s, part 1: live-confirmed (`networkctl status`) DHCP hands out `home.lan` as pod search-domain suffix, and unbound has no authoritative zone for it (unlike `fritz.box`), so every external lookup recurses and fails (~341ms avg). Terraform never declared `domain` on the DHCP network resources and the last state backup shows null -- live drift, likely a manual RouterOS change bypassing Terraform. Added `domain = ""` explicitly to force-correct on next Atlantis apply. Not yet applied (2026-07-07) |
| REL-059 | Reliability | **PARTIAL** | DNS query volume, part 2: added `local-zone: home.lan. static` to unbound (instant NXDOMAIN, zero recursion, doesn't wait on DHCP leases to renew like REL-058 does). Separately found ptbtime1/2/3.ptb.de (~24% of ALL DNS traffic, ~440k/7d) traced via AdGuard's query log to 3 client IPs on the Fritz!Box's own LAN (192.168.178.20/23/25) -- unrelated to k3s, just noticed at the same time. Added `local-data` overrides (current real IPs) so answering them is free regardless of those unidentified devices' query rate. Config-validated via a disposable container of the live unbound image (no unbound-checkconf binary in this minimal image). Not yet applied (2026-07-07) |
| REL-057b | Reliability | **RESOLVED** | Root-caused REL-057's ~40% recent Velero backup failure rate -- ruled out Garage CPU/memory/crash via Prometheus (all idle/flat during the failure windows), then found CNPG's own barman-cloud archiving for Authelia's Postgres was writing into the *same* Garage bucket Velero owns, tripping Velero's own bucket-validation (`BackupStorageLocation` was live `Unavailable`, "invalid top-level directories: [cnpg-postgres-authelia]"). Fixed with a new scoped bucket (`cnpg-backups`), verified a real base backup + WAL switch landing there *before* deleting the old 3632-object prefix from the shared bucket -- BSL flipped back to `Available` within 30s of the deletion, confirmed live (2026-07-07) |
| REL-060 | Reliability | **RESOLVED, awaiting merge** | paperless-gpt CrashLoopBackOff since 13:43, traced to `icereed/paperless-gpt:v0.26.0` (auto-merged via PR #314 same day) -- new entrypoint runs `addgroup` at startup, fails under this Deployment's `readOnlyRootFilesystem: true`. Rolled back to v0.25.1 (verified live: clean startup, `1/1 Running`), added the package to renovate.json's PR-only tier so future bumps get manual review. Live cluster still flaps back to v0.26.0 via ApplicationSet-controlled selfHeal until merged -- a standalone-Application syncPolicy pause (used elsewhere this session) doesn't hold for ApplicationSet-generated apps (2026-07-07) |
| REL-061 | Security | **RESOLVED, awaiting merge** | cloudflare-ddns's API token was a bare hand-created Secret since 2026-06-02, gone dead -- confirmed via Cloudflare's own verify endpoint ("Invalid API Token"). Same secret is also cert-manager's DNS-01 credential, meaning cert renewal would have failed too. Script never checked API response success and always exited 0, masking the failure from KubeJobFailed entirely. Fixed by reusing Terraform/Atlantis's already-working token (verified live: valid, active, real GET+PUT against the actual DNS record both succeeded) wired via a proper Vault ExternalSecret, plus making the script fail loud on real API errors. Separately found nextcloud-cron's "failure" was a single non-recurring event from a week+ ago still re-triggering Alertmanager's 2h repeat -- failedJobsHistoryLimit doesn't expire on its own; added ttlSecondsAfterFinished: 86400 to both CronJobs (2026-07-07) |
| REL-055b | Reliability | **RESOLVED** | Corrected REL-055's own misdiagnosis of the ArgoCD metrics-port GAP -- `/proc/net/tcp6` (not checked before) showed it was listening dual-stack the whole time. Real cause: k3s's built-in kube-router NetworkPolicy controller doesn't correctly enforce a bare `namespaceSelector: {}` "allow all namespaces" rule -- proved live (delete policy -> works, re-add identical rule -> blocked again, swap to `ipBlock: cidr: 10.42.0.0/16` -> works). Found and fixed the identical broken pattern on 4 more ArgoCD NetworkPolicies (applicationset-controller, dex-server, notifications-controller, repo-server) that were equally unreachable, not just the one port. Added a ServiceMonitor, confirmed live via Prometheus's targets API (`up`) and a real query (`argocd_app_info`, 42 results). All 5 policies were also untracked in git since the 2026-05-31 manual bootstrap -- brought under GitOps here too (2026-07-07) |
| REL-062 | Reliability | **CORRECTED, PROPOSED** | Original entry claimed PBS's vzdump and Velero's backup stacked at the same 03:00 instant -- WRONG, retracted here: mini runs CEST (UTC+2), vzdump's "03:00" is 01:00 UTC, Velero's schedule is 03:00 UTC -- 2 hours apart, never overlapped. Re-checked with a full week of Prometheus history: Velero's OWN backup alone pushes host temp to 82-90C every single night (2026-07-04 hit 90C with zero alert). 2026-07-07's alert wasn't a one-off stacking incident, it's this nightly pattern crossing the alert threshold. Moved schedule to 05:00 UTC (clear of vzdump's real window) as hygiene only -- explicitly not a thermal fix, since Velero alone already reaches 82-90C regardless of the hour. Real takeaway: this is a standing nightly near-freeze risk, not a rare fluke (2026-07-07) |
| REL-063 | Reliability | **CONFIRMED** | PBS vzdump (the hypervisor safety net, the one backup layer with a real live-tested restore, REL-052) showed ERROR on 7 consecutive nights (06-26 through 07-02), not the 3 first noticed. Pulled every failure's full task log: identical cause each time, VM 9000 (a stopped template, `tpl-debian-13-cloudinit`, not a real guest) timing out on a ZFS base-volume zvol device link, always the LAST item attempted after every real, data-bearing guest had already backed up successfully. The safety net was reliable throughout, including during the failure streak -- only a non-critical template's tail-end backup ever failed. Already fixed 5 days before this check (`exclude 9000` in /etc/pve/jobs.cfg, confirmed via the live command line since 07-03) by someone outside this session -- this pass confirmed and documented it, no remediation needed. Flagged: the fix itself has zero IaC trail, same class of gap as REL-057b's Garage bucket management (2026-07-07) |
| REL-064 | Reliability | **PENDING, 0/3 nights** | Post-Velero-fix thermal recheck: does peak nightly host temp actually drop below 80C after REL-062's schedule move (05:00 UTC, live as of 2026-07-07 16:03 UTC) plus separate physical cooling work, or does Velero's own IO/CPU load alone keep driving 82-90C regardless of schedule? Can't be answered yet -- the new schedule's first run hasn't happened. Documented pre-fix baseline (7 nights, 81.6-90.0C), exact PromQL methodology, and a decision rule stated in advance (below-80C -> RESOLVED by cooling; still 82-90C -> load-side fix needed, e.g. Velero concurrency limits/ionice/narrower defaultVolumesToFsBackup scope). Revisit 2026-07-10 UTC or later (2026-07-07) |
| REL-056 | Reliability | **PARTIAL** | Autonomy-readiness task 1: tiered Renovate auto-merge -- stateless/CI/dev-tooling patch-minor-digest auto-merges after CI-green + 3-day soak; a named stateful/critical list (Vault/Authelia/Garage/Vaultwarden/DBs/Nextcloud/Paperless/Immich/Gitea/Velero-plugin) plus all majors stay PR-only, grouped+labeled. Digest pinning added. Config-validated, NOT merged -- account owner reads the tiering first per instruction (2026-07-07) |
| REL-055 | Reliability | **RESOLVED** | Autonomy-readiness task 2: CrashLoopBackOff/KubeJobFailed/NodeNotReady existed as rules but shipped severity=warning, never routed to Discord -- added explicit alertname route. ArgoCD Degraded/OutOfSync had zero alerting AND its metrics port turned out to be dead (confirmed live via `/proc/net/tcp`, root cause not found) -- pivoted to `argocd-notifications-controller` (a generic webhook service reusing the same Discord URL), found and fixed a real nil-pointer bug in the sync-failed trigger expression live. cert-manager and Velero (goroutine-driven, no native Job -- `KubeJobFailed` could never catch it) had zero metrics scraping at all -- added ServiceMonitors + PrometheusRules for both. Every fix proven with a real fired alert reaching Discord, user-confirmed both times, not just config review. Also broke and immediately fixed ArgoCD's own application-controller mid-diagnosis (bad `kubectl patch` dropped its exec args, ~2min crash loop, reverted clean) (2026-07-07) |
| IAC-004 | IaC | **RESOLVED** | Re-checked after REL-038 unblocked the network stack's plan (it had never successfully planned before due to the same backend DNS issue, layered on top of years of never-applied drift). Real plan: destroys the 4 WAN Minecraft port-forward rules (`fwd_wan_minecraft`/`fwd_wan_cobblemon`/`dstnat_minecraft`/`dstnat_cobblemon`) -- **intentional** per PR #216 (2026-07-01, already merged) which moved Minecraft to a playit.gg tunnel instead. Was held from applying while the replacement DNS record was blocked by the Cloudflare token's missing DNS scope (2026-07-04). Unblocked 2026-07-05: rotated to a properly-scoped token (see REL-048), cut over `mc.woitzik.dev` to the playit.gg CNAME live, confirmed the tunnel reachable (`doing-sigma.gl.joinmc.link:25565` TCP open), then applied the 4-rule destroy (PR #286) -- same stale-import-block bug as GIT-008 (REL-047) blocked 3 of these 4 resources until that was found and fixed. Live-verified Minecraft still reachable via playit.gg after the router-side cleanup. |

---

## Drift Detection

*Last updated: 2026-06-28. The table below was verified live against the cluster — cells marked
OK are confirmed current, not assumed.*

| Resource | Git state | Live state | Delta |
|---|---|---|---|
| k3s-11/12/13 | Running, worker | Running (Ready) | OK |
| ct-mgmt-pbs-01 | Running | Verify live | Check `qm status` on mini |
| ct-srv-nfs-01 | Running (required by all PVCs) | Running | OK |
| ct-srv-ai-01 | Running (Ollama/paperless-gpt) | Verify live | Check `qm status` |
| ct-srv-docker-01 | Running (app_nodes group) | Verify live | Check `qm status` |
| ct-srv-media-acq-01 | Running (media acquisition) | Running | OK |
| ct-srv-jellyfin-01 | Running (Jellyfin LXC) | Running | OK |
| ct-dmz-proxy-01 | Running | Verify live | Check `qm status` |
| ct-dmz-games-01 | Running | Verify live | Check `qm status` |
| ArgoCD Applications | All apps Synced | All Synced | OK |
| vault-0 StatefulSet | 1/1 Running | 1/1 Running | OK (auto-unseal active) |
| immich-server | v2.7.5, port 2283 | v2.7.5, Running | OK |
| headscale client_secret | Should be in Vault | In ConfigMap plaintext | **DRIFT** (SEC-001 — open) |
| photos.woitzik.dev | Cloudflare Tunnel → immich-server:2283 | Reachable externally | OK |
| Cloudflare TF provider | `~> 5.0`, resources renamed + chunked_encoding | Pending Atlantis apply (PR #192 merged 2026-06-28) | Atlantis plan/apply needed |
