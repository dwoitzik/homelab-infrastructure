# ADR-023: Guard bulk background I/O jobs against the single shared NVMe

**Date:** 2026-08-19
**Status:** Accepted

## Context

`pve-mgmt-01` has one physical disk (the NVMe `local-lvm` thin pool) backing
everything: the 3 k3s VM disks (including `vm-srv-k3s-11`, the sole control-plane —
etcd-equivalent `kine`/SQLite writes and the apiserver live there), every LXC, and
every `local-path`-backed Kubernetes PV, including Garage's own metadata store
(`garage-meta`). This is a known, documented, unavoidable constraint on this hardware
(see `CLAUDE.local.md`'s Hardware inventory section and `docs/HARDWARE.md`) — there is
no separate disk to move any of this onto today.

This single shared disk has now caused **two separate host-wide incidents in one day**
(2026-08-19, see `phase8/LEDGER.md` Entries 39-40 for full detail):

1. A recurrence of the previously-documented NVMe write-timeout/abort pattern (first
   seen and partially mitigated per Entries 6-8) — root cause not fully re-established
   this time, but consistent with the same class of shared-disk write pressure. Froze
   `vm-srv-k3s-11` badly enough that SSH, the QEMU guest agent, and the k3s apiserver
   were all unresponsive; required a `qm reset`.
2. A `garage repair blocks` / `clear-resync-queue` invocation (run deliberately, as
   part of investigating unrelated Garage metadata corruption) grew Garage's internal
   block-resync backlog to 107,156 items and drove NVMe write latency to ~5 seconds,
   host load average to 25+, and made `home.woitzik.dev`/`photos.woitzik.dev` fully
   unreachable (connection timeouts, not even a 404) until the Garage pod was scaled
   to 0.

Incident 1 already has a real, existing, but until today undiscovered-as-drifted
mitigation: `vzdump`'s global `bwlimit`/`ionice` throttle plus per-VM `mbps_wr`/
`mbps_wr_max` write ceilings (`terraform/stacks/proxmox/vm.tf`, `/etc/vzdump.conf`).
Both were applied live during the original incident (2026-08-16) and had silently
never been brought under IaC — fixed as part of this same pass (PR alongside this
ADR). But **incident 2 is a different job entirely** — a Kubernetes pod's own
background worker, not a PVE-level `vzdump` backup — and vzdump's throttle has no
effect on it at all. Nothing in this repo throttled, rate-limited, or even warned
about a bulk in-cluster I/O job before this pass.

## Options considered

**Option A — cgroup-level block I/O limits on the Garage pod (`io.max`/blkio
weight).** Kubernetes has no first-class PodSpec field for block I/O bandwidth/IOPS
limits (unlike CPU/memory `resources`); enforcing this would mean either a custom
device plugin, hand-rolled cgroup file writes via a privileged init container, or a
CSI driver with per-volume QoS. `local-path` (this cluster's PV provisioner for
`garage-meta`) supports none of this. Real, but disproportionate engineering effort
for what this hardware can actually enforce today — rejected for now, noted as a
future option if the storage layer changes (e.g., a CSI driver that supports it, or
genuinely separate physical disks per workload class).

**Option B — Garage's own concurrency config (`block_max_concurrent_reads` /
`block_max_concurrent_writes_per_request`).** Real, documented, config-file-settable
knobs (confirmed against Garage's own reference docs, not guessed) that cap how many
blocks Garage itself reads/writes in parallel. Directly reduces the peak IOPS/
bandwidth *any* Garage background operation (resync, scrub, or normal S3 traffic) can
generate, at some cost to Garage's own throughput ceiling. Chosen as one layer —
cheap, durable (goes in the existing `garage-config` ConfigMap, survives a rebuild),
proportionate — but not sufficient alone: it caps steady-state concurrency, not the
sheer *size* of a 107k-item backlog suddenly wanting to run at once.

**Option C — a load-aware guard script wrapping any manual `garage repair`
invocation, checked into the repo (chosen, primary fix for incident 2's specific
trigger).** The actual proximate cause of incident 2 was a human/agent running a bulk
repair command without checking current host disk load first — exactly the kind of
mistake a cheap, mechanical pre-flight check prevents. `scripts/garage-repair-guard.sh`
checks live NVMe `%util`/write-await via `iostat` on `pve` before allowing a
`garage repair` subcommand to proceed, and refuses (with a clear message) if the disk
is already under load — the same read-only-check-first discipline
`pve-watchdog.sh` already applies for monitoring, now applied as a gate before a
known-risky manual action, not just an after-the-fact alert.

**Option D — a generic cluster-wide "bulk I/O lock" (e.g., a Kubernetes Lease or a
flag file) that any future bulk job must acquire before running, serializing vzdump,
Velero backups, Garage repairs, PBS jobs, etc.** Real and more general than Option C,
but meaningfully more infrastructure to build and maintain (a lock service, timeout/
staleness handling, teardown-on-crash semantics) for a problem that, so far, has
exactly one *manual, rare* trigger (an operator or agent deliberately running
`garage repair`) rather than multiple *automated, concurrent* schedulers actually
racing each other. Not built now — Option C covers the real trigger with far less
code; revisit this if a second automated bulk-I/O source appears and the two ever
need to actually coordinate rather than just each individually checking load first.

## Decision

Layer B (Garage concurrency config, conservative NVMe values) + Option C (a
checked-in, load-aware guard script for manual `garage repair` invocations) together.
Option A and D are documented and deliberately deferred, not silently dropped —
revisit A if the storage layer ever changes, revisit D if a second automated bulk-I/O
scheduler shows up and needs real coordination with the others rather than each
independently checking load.

This does not, and cannot, fully solve "one shared disk, many tenants" — that is a
hardware constraint this repo already documents as accepted (`docs/HARDWARE.md`,
"target recovery, not HA"). It solves the specific, real, twice-in-one-day failure
mode: an operator or agent starting a bulk I/O job without checking current load
first, with no mechanical guard stopping them.

## Consequences

- Any future manual Garage repair/maintenance work goes through
  `scripts/garage-repair-guard.sh` instead of calling `garage repair` directly —
  documented in the script's own usage text and in `docs/OPERATIONS.md`.
- Garage's own background operations run at a lower concurrency ceiling always, not
  just during manual repairs — a small, permanent throughput cost in exchange for a
  lower peak-contention ceiling.
- `vzdump`'s throttle (a different, already-existing mechanism, now IaC-tracked) and
  this ADR's guard cover the two bulk-I/O sources that have actually caused incidents
  so far. A third, different source showing up in the future is not automatically
  covered — this ADR's Option D discussion is where to start if that happens.

## Update, 2026-08-22: the predicted third source showed up — trivy-operator

Option D above named its own trigger condition: "a second automated bulk-I/O source"
that needs real coordination. That happened today. Redeploying Kyverno (new
ClusterPolicies with an admission-controller pod) coincided with a real
`KubeAPIServerHighLatency` incident (p99 8.5s, host load 33-57 on 16 threads, one
node briefly `NodeNotReady`) — Kyverno's own admission webhook was ruled out as the
cause (the cluster-wide resource-validating webhook had zero registered rules the
whole time), but three concurrent `trivy-operator` vulnerability-scan jobs (two
triggered by Kyverno's own new container images, one unrelated) plus a concurrent
Renovate dependency-update job were a real, confirmed, simultaneous I/O contention
source layered on top of an already-loaded host (`iostat` showed 10+ separate
thin-pool LVs pegged near 100% `%util` at once — a shared-thin-pool symptom, not any
single VM's disk).

The operator paused it live via `kubectl scale trivy-operator --replicas=0` — this
did **not hold**. `trivy-operator`'s ArgoCD Application has `selfHeal: true`, and
ArgoCD reverted the scale-down back to the chart's desired `replicas: 1` on its next
reconcile, silently resuming the scan jobs for over two hours before anyone noticed
load hadn't actually recovered. This is the exact same failure mode as the Kyverno
webhook `failurePolicy` fight from earlier the same day (a manual `kubectl` mitigation
against a GitOps-managed, selfHeal-enabled resource gets reverted, often within
minutes, sometimes silently) — now confirmed twice in one session against two
different controllers (Kyverno's own internal reconciler; ArgoCD's Application
selfHeal).

**Standing practice, effective now**: any live mitigation against a resource managed
by an `automated: {selfHeal: true}` ArgoCD Application (or, separately, against a
resource an in-cluster operator reconciles itself, like Kyverno's
`ValidatingWebhookConfiguration`s) must be **git-tracked in the same action**, not
applied as a bare `kubectl` command first with a follow-up commit "later." A `kubectl
scale --replicas=0` or `kubectl patch` against such a resource is not a real
mitigation — it is, at best, a temporary no-op until the next reconcile, and at worst
a false sense of safety while the underlying condition (in this case, sustained I/O
contention) continues unaddressed. The durable fix, applied for real this time
(`kubernetes/apps/trivy-operator/trivy-operator.yml`, `replicas: 0` with a comment
explaining why), is the only form that actually holds.

Option D (a generic cluster-wide bulk-I/O coordination lock across vzdump, Garage
repairs, PBS jobs, and now scanner operators) is **still deferred** — the trigger
condition named in the original decision technically fired, but the actual fix that
worked was the same class of solution as Option C (a specific, cheap, git-tracked
guard for the specific new source), not a general lock service. Revisit Option D only
if a future incident involves two or more of these bulk-I/O sources needing to
actively coordinate scheduling with each other (not just each independently avoiding
running during high load) — that has not happened yet.
