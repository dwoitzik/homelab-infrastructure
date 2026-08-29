# ADR-036: Pod Topology Spread to Prevent Single-Node Workload Concentration

**Date:** 2026-08-29
**Status:** Accepted (rebalance procedure below) — not yet executed. This ADR
is the plan; nothing in it has been applied to the live cluster.

## Context

`vm-srv-k3s-11` hung completely (SSH, guest-agent, and the QEMU monitor's
`info block` query all timed out; `info status` still answered, so the QEMU
process itself was alive — the guest OS was wedged, not the hypervisor).
Host-level `iostat` showed the LVM-thin devices backing this VM's disk at
87-100% utilization. The operator force-stopped and restarted the VM
(`qm stop 211 --skiplock 1` / `qm start 211`); the API server and all 3
nodes came back Ready. `headscale`'s own pod was never itself unhealthy
(stayed `2/2 Running` throughout) — it was unreachable because its node was
down, not because the pod crashed.

**Storage was still saturated after the restart**, independently
re-confirmed for this ADR (`iostat -x` on `pve-mgmt-01`, not assumed from
the incident report): the LVM-thin data/metadata devices sat at 97-99.9%
utilization, with discard latency spiking to 734ms on the physical NVMe.

## Root cause — verified, and more specific than the initial hypothesis

The initial working theory was that `local-path` StorageClass PVCs are
node-affine by design, and that this had pinned nearly the entire stateful
workload to `vm-srv-k3s-11` over time. **Checked directly rather than
assumed, and only partly true:**

- `local-path` PVCs (the genuinely node-pinned ones) are **already
  reasonably distributed**: 6 on `vm-srv-k3s-11`, 4 on `vm-srv-k3s-12`, 4 on
  `vm-srv-k3s-13` (`kubectl get pv -o custom-columns=...`, cross-referenced
  against each PV's `nodeAffinity`). The `-11` set is
  `postgres-n8n-1`, `home-assistant-config`, `postgres-authelia-1`,
  `tailscale-router-state`, `data-vault-0`, `open-webui-data` — real, but
  not "essentially everything."
- Garage's and Immich's library volumes (`garage-data-archive`,
  `immich-library-usb`) — assumed node-pinned, since they're statically
  provisioned rather than dynamically via a StorageClass — are **actually
  NFS-backed** (`nfsvers=4.1` in each PV's `mountOptions`). Not node-pinned
  at all.
- Cross-referencing live pod placement against this: the pods actually
  concentrated on `-11` right now — Garage, `immich-postgres`,
  `postgres-paperless`, every ArgoCD component (7 pods), Alertmanager,
  Grafana, `kube-state-metrics`, the Prometheus Operator, all 5 Loki pods,
  the blackbox/SNMP exporters, Tempo, plus the 6 genuinely-pinned
  `local-path` pods above — are overwhelmingly backed by **`nfs-client`
  storage or no storage at all**, not `local-path`.

**The real cause: nothing in this cluster has ever enforced pod spread.**
No `topologySpreadConstraints`, no `podAntiAffinity`, anywhere (`grep`
across every Helm-values `Application` and every plain Deployment/
StatefulSet manifest — zero matches). The workloads above aren't stuck on
`-11` by a storage constraint; they've simply never been moved since
whenever they first landed there — most plausibly because `-11` is the
original control-plane node and existed before `-12`/`-13` were fully
loaded up, and the default scheduler has no reason to actively rebalance
already-running pods away from a node once they're placed. This is
scheduling inertia, not a hard constraint — which is good news: most of it
is safe to fix by simply rescheduling, not by migrating data.

**Demonstrated live, not just inferred**: while investigating this (see
Verification below), a single routine operation — a full-cluster Velero
backup, the same kind that runs on schedule every night — was enough to tip
both `vm-srv-k3s-11` and `vm-srv-k3s-12` briefly `NotReady`. Deleting that
backup brought both back to `Ready` within seconds. This cluster's current
concentration is fragile enough that normal, expected operations can
destabilize it, not just unusual load.

This is very likely the real mechanism behind the `REL-012c`-class disk
I/O contention symptoms this repo already documents from earlier incidents,
and is consistent with the chronic-looking restart counts found while
investigating this (`postgres-n8n-1`: 121 restarts; several `kube-system`/
`kyverno`/`crowdsec` pods in the low hundreds) — a recurring pattern, not a
one-off.

## Decision

1. **Reschedule the NFS-backed / storage-less pods currently concentrated
   on `-11` onto `-12`/`-13`**, one at a time, verified healthy before
   moving to the next. No PV-level data migration is needed for these —
   deleting the pod (or `kubectl rollout restart` for a Deployment) is
   sufficient, since the data lives on NFS and follows the pod to wherever
   it's rescheduled. This is a scheduling change, not a storage migration.
2. **Add `topologySpreadConstraints` (soft — `whenUnsatisfiable:
   ScheduleAnyway`, not a hard requirement) to the workloads above**, so
   this doesn't silently re-accumulate on `-11` again. Soft rather than
   hard: this is a 3-node cluster with real, uneven resource profiles (one
   control-plane node, two workers) — a hard constraint risks pods going
   `Pending` when a genuinely-justified imbalance exists (e.g. control-plane-
   only tolerations), which is a worse failure mode than an imperfect
   spread.
3. **Leave the genuinely `local-path`-pinned pods alone for now**
   (`postgres-n8n-1`, `postgres-authelia-1`, `data-vault-0`, and the other
   three on `-11`). They're a real but modest contributor (6 of 14 total
   `local-path` PVCs), already not wildly unbalanced, and migrating them
   requires the higher-risk manual-copy procedure (`CLAUDE.local.md`'s own
   guardrail for PV-level changes: snapshot first, no CSI snapshot
   capability on this cluster, so a real data copy via a throwaway pod).
   Revisit only if `-11` is still hot after step 1-2 land and are proven
   over a real observation window.

## Rebalance procedure (step 1 — no data migration, NFS-backed only)

For each pod in the reschedule list below, **one at a time**, during a
deliberately low-traffic window, not as a single bulk operation:

1. Confirm a recent Velero backup exists and actually completed (see
   Verification below for today's — do not skip this because "it's just a
   reschedule," per `CLAUDE.local.md` guardrail 1).
2. Delete the pod (or `kubectl rollout restart deployment/<name> -n
   <namespace>` for Deployments; for the ArgoCD `application-controller`
   StatefulSet specifically, a plain pod delete is the equivalent — it has
   no PVC, its state lives in the cluster's own etcd-equivalent).
3. Wait for the replacement to be `Ready`, then verify against **real
   content**, not just pod status — examples: `immich-postgres` — a real
   query returns the expected row counts; `argocd-application-controller`
   — Applications resume syncing (watch for the `Unknown` wave to clear,
   the way it did after today's incident restart); Loki — a live log query
   against a known-recent log line still returns it; Grafana — dashboards
   still load and a panel backed by a persisted datasource still renders.
4. Only proceed to the next pod once the current one is confirmed healthy
   against real data, not merely `Running`.

**Reschedule list** (NFS-backed or storage-less, currently on `-11`):
Garage, `immich-postgres`, `postgres-paperless`, all 7 ArgoCD components
(`application-controller`, `applicationset-controller`, `dex-server`,
`notifications-controller`, `redis`, `repo-server`, `server`),
Alertmanager, Grafana, `kube-state-metrics`, the `kube-prometheus-stack`
operator, all 5 Loki pods (`loki-0`, `loki-chunks-cache-0`,
`loki-gateway`, `loki-results-cache-0`, `loki-wal-fix`), the blackbox and
SNMP exporters, Tempo, `velero` itself.

Given how many of these are core cluster infrastructure (ArgoCD, the
monitoring stack, Velero itself), this should be done as its own
deliberate, watched session — not folded into an unrelated change, and not
run unattended given today's demonstration that a routine operation was
enough to cause a brief `NotReady`.

## Prevention (step 2 — topology spread)

Add soft `topologySpreadConstraints` (`topologyKey: kubernetes.io/hostname`,
`maxSkew: 1`, `whenUnsatisfiable: ScheduleAnyway`) to:

- `kubernetes/system/monitoring/application.yml`'s Helm `values:` —
  `prometheus.prometheusSpec.topologySpreadConstraints`,
  `alertmanager.alertmanagerSpec.topologySpreadConstraints`,
  `grafana.affinity`/`grafana.topologySpreadConstraints` (chart-dependent
  key names, confirm against the pinned `kube-prometheus-stack` chart
  version before implementing).
- Loki's and Tempo's own Helm `values:` (same pattern, confirm each
  chart's exact key).
- ArgoCD's Deployments directly, if it's raw manifests rather than a Helm
  values block (confirm during implementation — `kubernetes/system/argocd/`
  currently shows CRD/ConfigMap files in this repo, the core install
  itself needs checking).
- Garage, `immich-postgres`, `postgres-paperless` as plain
  Deployment/StatefulSet manifests — add directly to `spec.template.spec`.

Exact manifest diffs are implementation work, not this ADR — this records
the decision and the constraint shape (soft, hostname-keyed, `maxSkew: 1`),
not the line-by-line YAML.

## Verification done for this ADR (today, read-only + one reversible check)

- **Disk saturation**: confirmed live via `iostat -x` on `pve-mgmt-01`
  after the VM restart — still 97-99.9% util on the LVM-thin devices, not
  settled just because the VM came back up.
- **`local-path` PVC distribution**: confirmed via `kubectl get pv`
  cross-referenced with each PV's `nodeAffinity` — 6/4/4, not
  "everything on `-11`."
- **Garage/Immich PV backing**: confirmed via each PV's `mountOptions`
  (`nfsvers=4.1`) — NFS, not node-pinned static volumes.
- **ArgoCD's mass `Unknown` sync status**: confirmed as a transient
  reporting artifact of `argocd-application-controller-0` itself having
  just restarted (`startedAt` matched the node-recovery window almost
  exactly) and actively reconciling (live log tail showed real,
  in-progress `Reconciliation completed` events across many apps) — not
  43 independent real failures. Matches this repo's own documented
  precedent for this exact pattern (`docs/RUNBOOK-alert-response.md`).
- **Today's failed Velero backups — confirmed, not assumed**:
  - `daily-backup-20260829050139` (onsite, 05:02): failed with `dial tcp
    ...:3900: connect: connection refused` against Garage — Garage's own
    pod restart timestamp (09:21:58) postdates this failure, confirming
    Garage was genuinely down at that moment (mid-incident), not a
    separate bug. Safe to expect the next scheduled run (or a deliberate
    manual retry, see caveat below) to succeed now that Garage is healthy.
  - `daily-offsite-20260829040039` (R2, 04:00): failed with a completely
    different, unrelated error — `501 NotImplemented: Header
    'x-amz-tagging' with value '' not implemented`. **This is a real,
    separate, chronic bug**, not caused by today's incident — the same
    `daily-offsite` schedule has failed 6 days running
    (2026-08-24 through 2026-08-29, checked directly via `kubectl get
    backups.velero.io`), predating this incident entirely. Cloudflare R2
    doesn't support the S3 object-tagging API call Velero/kopia sends by
    default. **Retrying will not fix this** — it needs its own
    investigation (likely a Velero/kopia config flag to disable tagging
    for the `r2-offsite` `BackupStorageLocation`, or an R2-side setting).
    Flagged here, not fixed — out of scope for this ADR.
- **A real manual verification backup was attempted and deliberately
  aborted**: triggered a one-off full-cluster backup
  (`post-incident-verify-20260829`, 24h TTL) to confirm the onsite path
  end-to-end. Partway through, `vm-srv-k3s-11` and `vm-srv-k3s-12` both
  went briefly `NotReady` — almost certainly this backup's own I/O load
  landing on the same already-concentrated, already-strained node.
  Deleted the backup immediately; both nodes returned to `Ready` within
  seconds, and no other pod showed lasting damage from the blip
  (`kubectl get pods -A` afterward showed only pre-existing, unrelated
  issues — `scrutiny`/`scanopy` `CreateContainerConfigError`, a
  `paperless` crash loop already 11h old — nothing new). **Not
  conclusive proof of causation, but strong enough correlation that a
  full manual backup retry is deliberately not being attempted again
  outside a watched window** — recommend either letting tomorrow's
  scheduled 05:00 run go naturally, or a deliberate, monitored manual
  retry, not an unattended one.

## Trade-offs (accepted)

- Soft spread constraints don't guarantee even distribution — they're a
  scheduling preference, not a hard rule. Accepted because a hard
  constraint risks pods going `Pending` on a 3-node cluster with uneven
  node roles, a worse failure mode than an imperfect spread.
- Rescheduling ArgoCD's own control plane, Velero, and the monitoring
  stack carries real, if brief, availability risk during the move itself
  — accepted because leaving them concentrated is the demonstrated worse
  risk (today's incident, plus the NotReady blip this same investigation
  triggered).
- The `local-path`-pinned pods stay on their current nodes for now,
  including two (`postgres-authelia-1`, `data-vault-0`) that are
  arguably higher-value to rebalance than some of the NFS-backed ones.
  Accepted because they're a smaller share of the real imbalance and the
  migration procedure for them is genuinely higher-risk — sequencing the
  safer fix first, revisiting this only if it proves insufficient.

## Consequences

- Implementation PR(s), not yet written: the actual
  `topologySpreadConstraints` manifest changes, and a runbook-style
  checklist for executing the pod-by-pod reschedule (this ADR has the
  list and the verification bar; a dedicated runbook under
  `docs/runbooks/` should carry the actual step-by-step commands once
  this is scheduled for real execution).
- `daily-offsite`'s R2 tagging bug needs its own fix, tracked separately
  from this ADR (it's unrelated to the topology problem, just discovered
  alongside it).
- No live changes were made by this ADR itself — the one live action
  taken during its investigation (the verification backup) was
  deliberately reverted, not left in place.
