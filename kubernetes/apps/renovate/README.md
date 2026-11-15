# Renovate

Dependency-update bot, runs as a CronJob (every 2 hours) against this repo.

## Storage

None — clones the repo fresh into a `/tmp` emptyDir on every run.

## Policy — encoded in `renovate.json` at the repo root, not just described here

- **Auto-merge** (after a 3-day release-age soak): patch/minor/digest updates on
  stateless Kubernetes manifests, GitHub Actions, pre-commit hooks, and Terraform
  providers.
- **Manual PR only, always**: any major version bump, and *any* update (patch, minor,
  or major) touching a named stateful/critical service — Vault, Authelia, Garage,
  Vaultwarden, Postgres, Redis/Valkey, Nextcloud, Paperless, Gitea, Immich, Velero's
  restic/kopia plugin, paperless-gpt. See `renovate.json`'s own `packageRules` for the
  exact list and the reasoning behind each rule (several trace back to real prior
  incidents — a major Terraform provider bump OOM'd this same CronJob once, for
  instance).

## Known gotchas

- **Memory limit is set generously above the actual heap cap** (V8's own heap plus git
  clone/worktree overhead runs 20-50% over the `--max-old-space-size` figure) — this
  was tuned after two real OOMKilled incidents from repo growth and a major Terraform
  provider bump respectively. Don't set the container memory limit close to the heap
  cap if you resize this.
- **Authenticates as a GitHub App** (`homelab-renovate-dwoitzik`, installed on this
  repository only; permissions: contents, pull requests, issues, workflows, statuses
  write; checks, metadata read). The `app-token` init container signs a JWT with the
  app's private key and exchanges it for a one-hour installation token, so no
  long-lived token exists. Vault `secret/renovate` holds `app-id`, `installation-id`
  and `private-key` (PEM). PRs and comments come from the app's bot account, which
  keeps them out of the owner's participation notifications. If runs stop, read the
  `app-token` container log first: a 401 there means the key or app ID is wrong, a
  404 means the installation ID is.
