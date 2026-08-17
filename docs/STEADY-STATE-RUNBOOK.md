# Steady-State Runbook

Companion to `docs/OPERATING-MODEL.md`. That document says what the system is supposed
to do; this one says what to actually do when it doesn't, or when you're adding
something new. Not every alert type described as "supposed to fire" has necessarily
been exercised by a real event yet — check before assuming silence means "nothing's
wrong."

## Adding a new service

1. **Where it goes**: application workloads go under `kubernetes/apps/<name>/` — picked
   up automatically by the `homelab-apps` ApplicationSet, no manual Application object
   needed. System/infrastructure components go under `kubernetes/system/<name>/` and
   need their own `Application` manifest with an explicit `directory.include` glob
   (**not** a wildcard — an untracked or silently-orphaned file in this directory has
   bitten this repo more than once: edits sat in git having zero live effect because
   nothing was watching the file).
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
   floods Discord with routine noise.
5. **Docs**: every component gets a README/runbook — what it is, how to deploy, how to
   restore, dependencies. Add a Mermaid diagram entry if it changes the architecture
   picture.
6. **Snapshot first**: before applying anything that touches running state (not a
   brand-new empty namespace), take a Proxmox VM/CT snapshot (or a manual PVC data
   copy for PV-level changes -- this cluster runs `local-path`/`nfs-client` storage,
   not Longhorn, so there's no CSI-level snapshot capability). If you can't snapshot,
   stop and ask — this is a hard guardrail, not a suggestion.

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

**`github.com token 401 unauthorized` / `Authentication failure`**: the `renovate-token`
Secret is populated from Vault via the `renovate-token` ExternalSecret (`refreshInterval:
1h`) — this error means the PAT *value stored in Vault* has expired or been revoked on
GitHub's side, not a sync problem. ExternalSecret will faithfully keep syncing an expired
token until the Vault value itself is replaced.

1. On GitHub, generate a replacement fine-grained PAT for the `dwoitzik` account scoped to
   `homelab-infrastructure` (contents + pull-requests + workflows: read/write), matching
   whatever expiry the previous one had.
2. Update the value in Vault at the path the `renovate-token` ExternalSecret reads from
   (check `kubectl get externalsecret renovate-token -n apps -o yaml` for the exact
   `remoteRef.key` if unsure).
3. Either wait for the next `refreshInterval` (≤1h) or force it:
   `kubectl annotate externalsecret renovate-token -n apps force-sync=$(date +%s) --overwrite`.
4. Confirm: `kubectl get secret renovate-token -n apps -o jsonpath='{.metadata.resourceVersion}'`
   changes, then wait for the next CronJob fire (`*/2h`) or trigger one manually
   (`kubectl create job -n apps renovate-manual-$(date +%s) --from=cronjob/renovate`) and
   check its log for a clean run (no `401`/`Authentication failure`).

**Zombie Failed Job/pod cleanup** (applies to *any* recurring CronJob, not just Renovate):
`failedJobsHistoryLimit` keeps old Failed Job objects around by design so they stay
visible for triage — but `kube_job_status_failed` stays `>0` for each one until deleted,
so `KubeJobFailed` keeps re-firing on every alert evaluation even after the underlying
cause (e.g. the 401 above) is long fixed. Once the root cause is confirmed resolved
(latest 1-2 runs `Complete`), clear the backlog:

```bash
# List failed Jobs for the CronJob in question
kubectl get jobs -n apps --sort-by=.metadata.creationTimestamp | grep '<cronjob-name>-' | grep -v Complete

# Delete them (cascades to their pods)
kubectl delete job -n apps <job-name> [<job-name> ...]

# Some pods can outlive their Job object (e.g. TTL/GC timing) — sweep stragglers directly
kubectl get pods -n apps | grep '<cronjob-name>-' | grep -v Completed
kubectl delete pod -n apps <pod-name> [<pod-name> ...]
```

Alert clears once `kube_job_status_failed` has no remaining series for that job name
(check against Alertmanager's `repeat_interval` for `KubeJobFailed` — allow one cycle
before assuming cleanup didn't take).

### `KubeNodeNotReady`

Check `kubectl get nodes` and `kubectl describe node <name>` for the reason (kubelet
down, network partition, resource exhaustion). All 3 k3s VMs are guests on the single
Proxmox host (`pve-mgmt-01`, SSH alias `pve`) — also check the host directly
(`qm status`, `ssh pve`). This hardware has a documented history of `local-lvm`
thin-pool exhaustion causing host-level crashes (NVMe write timeouts under I/O
pressure, not ZFS -- the boot/VM disk moved off ZFS to LVM-thin in the 2026-08-13
disaster-recovery rebuild; ZFS now only backs the USB `archive` pool), which can
manifest as nodes going NotReady under load. See `phase8/LEDGER.md` Entries 6-8 for a
real incident and its resolution (fstrim + write-ceiling throttling + reclaiming
orphaned VMs).

### `CertManagerCertNotReady` / `CertManagerCertExpirySoon`

`kubectl describe certificate <name> -n <ns>` and `kubectl describe certificaterequest
-n <ns>` for the ACME/issuer error. Usually a Cloudflare API token issue (DNS-01
challenge) or a rate limit from Let's Encrypt. `CertManagerCertExpirySoon` at 7 days out
is an early warning — if it's still firing at 3 days out, escalate urgency, don't just
re-mute it.

### `VeleroBackupFailed` / `VeleroBackupPartialFailure`

`kubectl logs -n velero deploy/velero --tail=200 | grep <backup-name>` for the actual
error. Garage (the in-cluster S3 backend) has previously shown an intermittent
`BackupStorageLocation: Unavailable` error caused by another workload (CNPG's Postgres
backup archiving) writing into the same shared bucket Velero owns — Velero's own bucket
validation flags the unrecognized directory. Fixed once by giving CNPG its own scoped
bucket, but the failure mode is worth knowing if it resurfaces: check
`kubectl describe backupstoragelocation -n velero default` for the exact message before
assuming it's something new. Velero restore has been tested successfully at least once
(a full namespace restore, cross-checked byte-for-byte against live data) — not a
blanket guarantee for every service, but no longer entirely unverified territory either.

### ArgoCD `on-health-degraded` / `on-sync-failed` / `on-sync-status-unknown`

Check `https://argo.woitzik.dev/applications/<name>` directly — the Discord message
links straight to it. `Unknown` sync status is usually a bad `path:`/`targetRevision`
in the Application spec or a repo access issue, not the app's own manifests being
wrong. `Degraded` health means the app's own resources report unhealthy (check
`kubectl describe` on the specific resource ArgoCD flags) — remember selfHeal is on
everywhere, so if you're debugging by editing live resources, either work fast or
temporarily set `syncPolicy.automated: null` on that one Application first — selfHeal
will silently revert live edits back to git's current state within seconds otherwise
— and restore it before you finish.

## Recurring cadence (nothing here is optional busywork — each ties to a documented incident)

- **Renovate**: runs every 2h automatically. No manual cadence needed beyond reviewing
  the PR-only tier's PRs when they show up.
- **Full-repo lint/validate**: on every push via pre-commit `pre-push` stage + CI —
  no separate manual cadence.
- **Gitleaks full-history + baseline re-verification**: periodic manual re-run
  recommended (`gitleaks detect --no-git --source=. --baseline-path
  .gitleaks-baseline.json`) — a baseline entry can quietly go stale and hide a real
  still-live secret that the pre-commit hook alone would never catch; found this happen
  once already.
- **DR drill**: no fixed cadence yet. A full namespace restore has been tested once —
  worth repeating periodically and extending to other services, not something to
  rediscover for the first time mid-incident.
