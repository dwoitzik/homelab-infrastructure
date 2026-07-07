# Steady-State Runbook

Companion to `docs/OPERATING-MODEL.md`. That document says what the system is supposed
to do; this one says what to actually do when it doesn't, or when you're adding
something new. If an alert type here isn't wired yet, `docs/AUTONOMY-STATUS.md` says
so — check there before assuming silence means "nothing's wrong."

## Adding a new service

1. **Where it goes**: application workloads go under `kubernetes/apps/<name>/` — picked
   up automatically by the `homelab-apps` ApplicationSet, no manual Application object
   needed. System/infrastructure components go under `kubernetes/system/<name>/` and
   need their own `Application` manifest with an explicit `directory.include` glob
   (**not** a wildcard — see REL-014/035/042 in `docs/AUDIT.md` for why an untracked or
   silently-orphaned file in this directory has bitten this repo three times).
2. **Secrets**: never commit a plaintext secret. Use an `ExternalSecret` pointing at
   Vault (`ansible/group_vars/all/vault.yml`, `vault_` prefix convention for the
   underlying Ansible-side secret, or a `secret/<app>` path in Vault directly for
   cluster-native secrets). `creationPolicy: Owner` if this repo is the only writer to
   the resulting Secret; `Merge` if another controller (ArgoCD notifications, some
   operator) also writes keys to the same Secret object.
3. **If it's stateful** (has its own database, PVC with real data): add it to
   `renovate.json`'s stateful/critical `packageRules` group so Renovate doesn't
   auto-merge a bump into it. Add it to the Velero backup scope check — the schedule
   backs up `["*"]` namespaces by default, so this is usually automatic, but confirm
   the namespace isn't excluded.
4. **Alerting**: if it exposes Prometheus metrics, add a `ServiceMonitor` (co-locate
   with a `<service>-alerts.yml` PrometheusRule file, matching the existing
   `hardware-temp-alerts.yml`/`postgres-alerts.yml`/`cert-manager-alerts.yml` pattern in
   `kubernetes/system/monitoring/`). If a new alert needs to reach Discord and isn't
   `severity: critical`, add its `alertname` explicitly to the warning-tier route in
   `alertmanager-config.yml` — don't just flip to routing all `severity: warning`, that
   floods Discord with routine noise (see REL-055).
5. **Docs**: every component gets a README/runbook per `CLAUDE.local.md`'s quality bar
   — what it is, how to deploy, how to restore, dependencies. Add a Mermaid diagram
   entry if it changes the architecture picture.
6. **Snapshot first**: before applying anything that touches running state (not a
   brand-new empty namespace), take a Proxmox VM/CT snapshot or Longhorn/PV snapshot.
   If you can't snapshot, stop and ask — this is a hard guardrail, not a suggestion.

## Responding to each alert type

### `severity: critical` (generic — host temp, control-plane down, storage >93%, Postgres critical)

These are unambiguous "something is actually breaking" signals. Check the linked
Grafana dashboard / `kubectl describe` on the named resource first; these don't
generally need investigation to confirm they're real, they need a fix.

### `KubePodCrashLooping`

`kubectl logs --previous` on the named pod first — the crash reason is almost always in
the previous container's exit logs, not the current (crash-looping) attempt's stdout.
Check recent changes to that app first (Renovate bump? manual edit?) before assuming
it's unrelated infra noise.

### `KubeJobFailed`

If the namespace is `apps` and the job name starts with `renovate-`, check
`kubectl logs job/<name> -n apps` — usually a GitHub API rate-limit or a bad
`renovate.json` syntax error from a recent edit. Not urgent (it retries next 2h cycle),
but repeated failures mean Renovate has been silently not-updating anything.

### `KubeNodeNotReady`

Check `kubectl get nodes` and `kubectl describe node <name>` for the reason (kubelet
down, network partition, resource exhaustion). If it's `mini`-hosted (all 3 k3s VMs
are), also check the host directly (`qm status`, `ssh` to `mini`) — this hardware has a
documented history of ZFS I/O stalls under RAM pressure (REL-016), which manifests
exactly as nodes going NotReady under load.

### `CertManagerCertNotReady` / `CertManagerCertExpirySoon`

`kubectl describe certificate <name> -n <ns>` and `kubectl describe certificaterequest
-n <ns>` for the ACME/issuer error. Usually a Cloudflare API token issue (DNS-01
challenge) or a rate limit from Let's Encrypt. `CertManagerCertExpirySoon` at 7 days out
is an early warning — if it's still firing at 3 days out, escalate urgency, don't just
re-mute it.

### `VeleroBackupFailed` / `VeleroBackupPartialFailure`

`kubectl logs -n velero deploy/velero --tail=200 | grep <backup-name>` for the actual
error. As of REL-057, Garage (the in-cluster S3 backend) has an unexplained
intermittent `HeadObject` timeout — if that's the cause again, this is a known-but-not-
root-caused issue, not a new one. **Do not assume "Completed" backups are restorable**
— no Velero restore has ever been tested (REL-057); if you're responding to this alert
because you actually need data back, treat the restore itself as unverified territory,
not a solved problem.

### ArgoCD `on-health-degraded` / `on-sync-failed` / `on-sync-status-unknown`

Check `https://argo.woitzik.dev/applications/<name>` directly — the Discord message
links straight to it. `Unknown` sync status is usually a bad `path:`/`targetRevision`
in the Application spec or a repo access issue, not the app's own manifests being
wrong. `Degraded` health means the app's own resources report unhealthy (check
`kubectl describe` on the specific resource ArgoCD flags) — remember selfHeal is on
everywhere, so if you're debugging by editing live resources, either work fast or
temporarily set `syncPolicy.automated: null` on that one Application first (see
REL-055/042 for why — selfHeal will silently revert live edits back to git's current
state within seconds otherwise), and restore it before you finish.

## Recurring cadence (nothing here is optional busywork — each ties to a documented incident)

- **Renovate**: runs every 2h automatically. No manual cadence needed beyond reviewing
  the PR-only tier's PRs when they show up.
- **Full-repo lint/validate**: on every push via pre-commit `pre-push` stage + CI —
  no separate manual cadence.
- **Gitleaks full-history + baseline re-verification**: periodic manual re-run
  recommended (`gitleaks detect --no-git --source=. --baseline-path
  .gitleaks-baseline.json`) — SEC-013 found 2 real still-live secrets hiding behind a
  stale baseline entry that the pre-commit hook alone would never have caught.
- **DR drill**: no fixed cadence yet, but REL-057 found Velero restore has never been
  tested even once — the next one shouldn't be "when a real incident forces it."
