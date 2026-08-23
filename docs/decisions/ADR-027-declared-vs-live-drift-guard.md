# ADR-027: Declared-vs-live drift guard for non-ArgoCD-managed manifests

**Date:** 2026-08-23
**Status:** Accepted

## Context

"Declared in git, never actually applied to the live cluster" has bitten
this mission four separate times, across four different resource kinds:

1. The `pve-exporter` ExternalSecret.
2. A Kyverno ClusterPolicy.
3. The `database` namespace's NetworkPolicy.
4. The dead man's switch CronJob (`kubernetes/system/monitoring/
   dead-mans-switch.yml`) -- merged to main via PR #517, never
   `kubectl apply`'d, found only by a manual live-vs-git sweep during an
   unrelated repo audit. This is the worst instance of the pattern: the
   entire point of a dead man's switch is to catch the cluster going
   silent, and a manifest sitting in git provides zero protection against
   that failure mode until it's actually running.

All four share the same root cause: these files are standalone raw
manifests under `kubernetes/system/`, not wrapped in an ArgoCD
`Application`. ArgoCD's own `selfHeal` keeps everything it manages in
sync with git automatically -- but nothing reconciles the files nobody
wrapped in an `Application`, so a `kubectl apply` that never happened (a
forgotten step after a merge, an agent session that ran out of context
mid-task) is invisible until something downstream breaks and someone goes
looking.

`kubernetes/system/postgres/` turned out to be an instructive fifth data
point discovered while validating this guard: it IS ArgoCD-managed (an
`Application` named `postgres-cluster`, directory-source, no
`kustomization.yaml`), and its own sync is stuck in a loop (`Health:
Unknown`, `autoHealAttemptsCount: 9` on one resource that still isn't
live) -- a real, separate bug, not something this guard is meant to fix.
It's a useful boundary case: this guard's job is to report ground truth
(declared vs. live), not to diagnose why an ArgoCD-managed resource
that *should* self-heal isn't. Flagged separately in
`phase8/QUESTIONS.md`, not fixed here.

## Decision

Built a scheduled check (`.github/workflows/drift-check.yml`, every 30
minutes + manual `workflow_dispatch`) that walks every YAML file under
`kubernetes/system/`, extracts every declared object that isn't an
ArgoCD `Application`/`AppProject`/`ApplicationSet` (those are already
self-healed) or a `Secret` (see below), and confirms each one actually
exists live via `kubectl get`. Any gap fails the job and pushes an ntfy
alert.

Considered the other option the brief raised -- bringing every standalone
CronJob/PrometheusRule/ExternalSecret under ArgoCD's own scope instead --
and rejected it for this pass: it would mean re-architecting how a wide
variety of already-working files are managed (some of them, like Kyverno's
`policies.yml`, are deliberately direct-`kubectl`-apply because an agent
needs to hand-edit them live during an incident without fighting selfHeal
-- see ADR-023), for a benefit ArgoCD-wrapping doesn't actually provide:
the failure mode isn't "these files drift from git," it's "nobody ever
ran the first apply." A diff-based guard catches that regardless of *why*
a file is standalone, and extends automatically to any new standalone
file added later without a design decision about how to bring it into
ArgoCD's world.

### Why a scheduled GitHub Actions job, not an in-cluster CronJob

The runner already exists (`ct-srv-atlantis-01`, ADR-021) and already has
network access to the apiserver. Running the check from outside the
cluster is also closer to what it's actually verifying: "is this really
live," not "does a pod inside the cluster agree it's live" -- a
distinction that matters if the apiserver itself, or this cluster's own
alerting path, is what's actually broken.

### Credential handling

A dedicated `drift-checker` ServiceAccount (`kubernetes/system/
infrastructure/drift-checker-rbac.yml`) bound to the built-in `view`
ClusterRole plus a narrow, explicit read-only addition for every CRD
group `view` doesn't aggregate (Kyverno, CNPG, Traefik, MetalLB,
cert-manager, chaos-mesh, Velero, Prometheus Operator, and
`rbac.authorization.k8s.io` itself -- `view` deliberately excludes
Role/ClusterRole read by design, confirmed live: the first real run of
this checker came back with 69/211 objects "missing" that were false
positives from this exact gap). `Secret` is excluded from the guard's
scope entirely on purpose: checking whether a Secret exists needs
`get`/`list` RBAC on secrets, which grants the same credential the
ability to read secret *values* too -- not a trade worth making for a
read-only credential that lives on a CI runner's disk, especially given
Secrets are the least silent of the four incident classes this guard
targets (a missing Secret crash-loops its consumer pod visibly, see the
paperless-ngx v3 `PAPERLESS_SECRET_KEY` incident the same session this
guard was built).

The credential itself (a long-lived ServiceAccount token, appropriate for
an external scheduled process rather than a short-lived per-run
`TokenRequest`) is deployed to the runner's own local disk via Ansible
(`github_actions_runner` role), not stored as a GitHub Actions secret --
this mission's available PAT lacks the `secrets:write` permission needed
to set repo secrets via the API, and a self-hosted runner has persistent
local storage anyway, so there's no real downside to keeping it there
instead of fighting that permission gap. The ntfy.sh alert topic (this
operator's real, in-use notification channel, whose only protection is
its randomized name) is deployed the same way for the same reason --
it can't go in the workflow YAML itself since this is a public portfolio
repo.

## A second, distinct failure class this guard does NOT catch

Found live the same night this guard was built, while resolving PR #463
(migrate Headscale off k3s): a real, currently-running native Headscale
Docker container on `rpi-srv-02`, entirely outside git, from an
apparently-abandoned earlier attempt at exactly what #463 proposed. Two
stale node registrations, both confirmed offline before decommissioning.

This is the mirror image of the failure class above: **undeclared and
manually run**, rather than **declared and never applied**. This guard
only ever looks at what's declared in `kubernetes/system/` and asks "is
this live" -- it has no way to notice something running that was never
declared anywhere, on a host (`rpi-srv-02`, plain Docker, not even a k3s
node) this guard doesn't look at at all. Worth naming as a real, separate
gap rather than pretending this guard covers more ground than it does --
closing it would need a genuinely different mechanism (an inventory
sweep of every host's running containers/services against what Ansible
and Kubernetes together declare, which is a much bigger undertaking than
this guard and not attempted here).

## Verification

Proved this catches a real gap by deliberately deleting a fully-applied,
non-ArgoCD-managed resource (`kubectl delete cronjob dead-mans-switch -n
monitoring`) and re-running the checker: it reported `MISSING: CronJob/
dead-mans-switch` immediately, exit code 1. Re-applied the CronJob
straight after (never left the real dead man's switch down). Separately,
the guard's very first properly-RBAC'd run found three genuine,
pre-existing gaps with zero prompting: a `PodMonitor` for `postgres-
authelia` and two chaos-mesh `Schedule`s, all declared in git and never
applied -- the exact failure class this guard exists to catch, caught on
day one. The chaos-mesh Schedules were safe to apply immediately (both
use opt-in label selectors, confirmed zero pods currently match); the
PodMonitor hit the ArgoCD sync-loop bug described above and is tracked
separately rather than fought.

## Consequences

- Every future standalone manifest under `kubernetes/system/` gets this
  protection automatically -- no per-file opt-in needed.
- A real, if narrow, credential now lives on `ct-srv-atlantis-01`'s disk
  with read access across most of the cluster. Scoped as tightly as this
  guard's actual needs allow (see above); revisit if the guard's scope
  ever needs to grow.
- The 30-minute check interval is a judgment call, not a measured
  requirement -- tight enough to catch a forgotten apply the same session
  it happens, loose enough not to spam the self-hosted runner. Adjust if
  it proves too noisy or too slow in practice.
- Does not cover `kubernetes/apps/` (ArgoCD ApplicationSet-managed,
  already self-healed) or anything outside `kubernetes/system/` entirely
  (Terraform, Ansible-templated host configs, the orphan-headscale class
  described above).
