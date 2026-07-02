# Pending Major-Version Upgrades

Four Renovate PRs are open for major-version bumps on stateful/critical services
(PR #204 vault-unseal CLI, PR #214 postgres for nextcloud+paperless, PR #212
nextcloud app, PR #202 immich-postgres). Renovate only bumps the image tag — none
of these are safe to merge as-is, because a bare image swap on a database
container does **not** perform the actual data/schema migration; the new
major-version binary will refuse to start against the old on-disk format
(Postgres, Nextcloud) or may behave unpredictably against a mismatched server
(Vault CLI).

This doc is the migration plan for each. Nothing here has been executed — each
section needs an explicit go-ahead before its steps are run, per one section at a
time (see `docs/AUDIT.md` REL-027..030 for tracking).

**General rule for all four:** snapshot the LXC/VM the k3s node runs on via Proxmox
*and* take an application-level backup (pg_dump, raft snapshot, etc.) before
touching anything — the Proxmox snapshot alone won't help mid-migration since the
apply happens inside a running pod, not at the VM level.

---

## REL-027 — Vault unseal-helper CLI: 1.21.4 → 2.0.3 (PR #204)

**Scope correction:** this PR does **not** touch the actual Vault server. The
server's version comes from the `hashicorp/vault` Helm chart default
(`kubernetes/system/vault/application.yml`, chart `0.28.1`, no explicit
`server.image.tag` override) and is untouched by this PR. #204 only bumps the
image used by `kubernetes/system/vault/unseal.yml` — a helper pod that shells out
to the `vault` CLI to call `operator unseal` against the real server over HTTP
after every restart (the REL-007 fix).

**Risk:** low-medium. Not a data-format risk (the CLI holds no state), but a
**functional** risk — if `unseal.yml`'s script parses CLI output/expects specific
flag behavior and `vault` 2.0's CLI changed either, the automated unseal could
silently stop working, reopening the exact cascading-ExternalSecret-failure gap
REL-007 fixed. This wouldn't be noticed until the next full cluster/VM restart.

**Steps:**

1. Check the CLI's `operator unseal` and `operator raft snapshot save` invocation
   against `hashicorp/vault:2.0.3` for flag/output changes vs 1.21.4 (read
   upstream changelog; if a local Docker daemon is available, `docker run --rm
   hashicorp/vault:2.0.3 vault operator unseal -h` and diff against 1.21.4's help
   output).
2. Take a raft snapshot of the real server first regardless (cheap insurance,
   doesn't depend on this PR): `kubectl exec -n vault vault-0 -- vault operator
   raft snapshot save /tmp/vault.snap`, then `kubectl cp` it out.
3. Merge #204, let ArgoCD sync the new `unseal.yml` image.
4. Force a real test of the unseal path without waiting for a real restart:
   `kubectl delete pod -n vault vault-0` (single-instance, standalone raft — pod
   restart re-seals until the unseal job runs) and watch `unseal.yml`'s pod logs
   complete successfully and `vault status` report `Sealed: false`.
5. Rollback: revert the image tag in `unseal.yml` via git revert + Atlantis-free
   direct kubectl apply if step 4 fails (this manifest is plain-apply, not CNPG/
   Helm-templated) — no data was touched, so this is a clean revert.

---

## REL-028 — Postgres for Nextcloud + Paperless: 16.14 → 18.4 (PR #214)

**Scope correction:** this is **not** the Authelia CNPG cluster — CNPG's
`postgres-authelia` (`kubernetes/system/postgres/cluster.yml`) has no explicit
image tag and is managed by the CloudNativePG operator, untouched by Renovate.
PR #214 bumps two independent bare `StatefulSet` Postgres instances:
`postgres-nextcloud` (`kubernetes/apps/nextcloud/nextcloud.yml`) and
`postgres-paperless` (`kubernetes/apps/paperless/stack.yml`). Treat as two
separate migrations sharing one PR — split the PR into two before executing so
one can be rolled back independently of the other.

**Risk:** high if done as a bare image swap — Postgres major versions have an
incompatible on-disk format; PG18 will refuse to start against a PG16 data
directory. Standard fix is dump/restore (no in-place `pg_upgrade` binary is
available inside these slim `postgres:*-alpine`/`postgres:*` images without
extra tooling).

**Steps (repeat per app — nextcloud first since paperless is independent):**

1. Put the app in maintenance/stopped state (Nextcloud: `occ maintenance:mode
   --on` via `kubectl exec`; Paperless: scale its Deployment to 0 so nothing
   writes during the dump).
2. `kubectl exec -n apps postgres-nextcloud-0 -- pg_dump -U <user> <db> >
   /tmp/nextcloud-pre18.sql` (same pattern for paperless) — pull it out with
   `kubectl cp` to the workstation, don't leave it only inside the pod.
3. Take a Velero on-demand backup of the PVC as a second recovery path:
   `velero backup create nextcloud-pg-pre18 --include-namespaces apps
   --selector app=postgres-nextcloud`.
4. Bump the image tag to `18.4`/`18.4-alpine`, but point `PGDATA` at a **fresh**
   PVC (new `volumeClaimTemplate` name or a temporary second PVC) — do not let
   PG18 attempt to start against the existing PG16 data directory even
   accidentally.
5. Once the new PG18 pod is `Ready` with an empty fresh database, restore:
   `kubectl exec -i -n apps postgres-nextcloud-0 -- psql -U <user> <db> <
   /tmp/nextcloud-pre18.sql`.
6. Bring the app back (`occ maintenance:mode --off` / scale Paperless back to 1),
   verify basic read/write (Nextcloud: log in, list a folder; Paperless: search
   for an existing document, confirm OCR text still indexed).
7. Only after a verified-good day, delete the old PG16 PVC.
8. Rollback if step 5/6 fails: point the app back at the untouched old PG16 PVC
   (nothing was deleted yet), revert the image tag.

---

## REL-029 — Nextcloud app: 30.0.17 → 34.0.1 (PR #212)

**Depends on REL-028's nextcloud half being done first** (Nextcloud 34 requires
a modern Postgres; do the DB upgrade before the app upgrade so app upgrade steps
aren't run twice).

**Risk:** high — Nextcloud's updater/`occ upgrade` explicitly refuses to skip
major versions. Going from 30 to 34 needs **four sequential** upgrade passes
(30→31→32→33→34), each running full DB schema migrations and app-compatibility
checks. A direct image swap to `34.0.1-apache` against a v30 database will fail
outright (`occ` detects the version gap and blocks).

**Steps:**

1. Back up `nextcloud-data` and `nextcloud-db-data` PVCs (Velero on-demand
   backup, same as REL-028 step 3) — full user file tree + DB.
2. `occ maintenance:mode --on`.
3. For each intermediate major (31, 32, 33, 34 in order):
   - Bump the three `nextcloud:*-apache` image references in
     `kubernetes/apps/nextcloud/nextcloud.yml` to that major's latest patch tag.
   - Apply, wait for the pod to be `Ready`.
   - `kubectl exec -n apps <nextcloud-pod> -- occ upgrade` — this runs that
     version's DB migrations. Do not proceed to the next major until this exits
     0 and `occ status` reports the new version with no errors.
   - Check the admin-facing "apps" screen (or `occ app:list`) for any bundled
     app disabled by the upgrade due to incompatibility — note it, don't
     auto-re-enable blindly.
4. After reaching 34.0.1, `occ maintenance:mode --off`, verify login + file
   list + at least one installed app (whichever the user actually uses) still
   works.
5. Rollback per step: if an intermediate `occ upgrade` fails, restore the PVC
   backup from step 1 and revert the image tag to the last known-good major —
   don't try to "fix forward" mid-migration-chain, Nextcloud's upgrade state
   machine assumes each step completed cleanly.

**Time cost:** four full upgrade-and-verify cycles — budget this as its own
session, not a quick merge.

---

## REL-030 — Immich Postgres (VectorChord): 14 → 16 (PR #202)

Scope: `immich-postgres` `StatefulSet` (`kubernetes/apps/immich/immich.yml`),
image `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` →
`16-vectorchord0.4.3-pgvectors0.2.0`. Same VectorChord/pgvecto extension version
on both tags (`0.4.3`) — the extension itself isn't changing, only the Postgres
major version underneath it, which lowers risk somewhat vs. an extension bump,
but the PG14→16 on-disk format is still incompatible, same class of problem as
REL-028.

**Risk:** high for data (largest PVC in the cluster — the entire photo library's
metadata + face/CLIP embeddings), medium for the app (Immich itself isn't
version-pinned by this PR, only its DB).

**Steps:**

1. Stop `immich-server` and `immich-microservices` (scale to 0) so nothing
   writes mid-migration; leave `immich-ml` down too (it depends on the DB via
   the server, not directly, but no reason to leave it warm).
2. `kubectl exec -n apps immich-postgres-0 -- pg_dumpall -U <user> >
   /tmp/immich-pre16.sql` — use `pg_dumpall`, not `pg_dump`, since Immich's
   VectorChord setup uses extensions/roles that a single-database dump can miss.
   Pull it out via `kubectl cp` immediately (this file will be large — check
   `df` on wherever it lands first).
3. Velero on-demand backup of the `immich-postgres` PVC as a second recovery
   path, same pattern as REL-028 step 3.
4. Bump the image tag to the `16-vectorchord...` tag, targeting a **fresh** PVC
   (same reasoning as REL-028 step 4 — never let the new major start against the
   old data dir).
5. Once the fresh PG16+VectorChord pod is `Ready`, restore: `kubectl exec -i -n
   apps immich-postgres-0 -- psql -U <user> < /tmp/immich-pre16.sql`.
6. Verify the VectorChord extension actually loaded post-restore
   (`SELECT * FROM pg_extension;` inside the pod) before restarting Immich —
   this is the step most likely to silently half-fail (extension present in the
   dump's `CREATE EXTENSION` statement but binary not available/compatible in
   the new image).
7. Scale `immich-server`/`immich-microservices`/`immich-ml` back up. Verify: log
   in, browse an existing album (confirms basic DB read), run a text/CLIP search
   for something known to exist (confirms the vector index survived and
   VectorChord is actually functioning, not just present).
8. Rollback if step 6/7 fails: point Immich back at the untouched old PG14 PVC
   (nothing deleted), revert the image tag.

---

## Suggested order

REL-027 (lowest risk, ~30 min) → REL-030 (isolated, one app) → REL-028
nextcloud-half + REL-029 together (they're coupled) → REL-028 paperless-half
(isolated, do whenever). Don't batch more than one on the same day — each needs
a clean verification window before the next.
