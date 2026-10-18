# ADR-057: In-cluster image scanning is paused; PR CI owns the vulnerability gate

- **Status**: Accepted and applied, 2026-10-16
- **Relates to**: ADR-034 (single DRAM-less NVMe), ADR-053/ADR-056 (the pve watchdog,
  which had been re-tuned to tolerate exactly this I/O load), PR #908 (the vault-unseal
  I/O fix this work followed on from), PR #909, `kubernetes/apps/trivy-operator/`

## Context

Fixing the vault-unseal loop (PR #908) dropped host disk writes from ~19 MB/s to near
zero, but the sustained I/O did not disappear: `pve-mgmt-01` still showed ~16 MB/s of
24/7 writes originating from `vm-srv-k3s-11`, and `pidstat -d` put the top writer inside
the VM. Traced to the Trivy Operator's scan jobs, which were not completing but
retrying:

```text
FATAL unable to initialize fs cache: cache may be in use by another process: timeout
```

Every retry re-downloaded the Trivy DB and re-pulled the target image layer, so the
operator was paying full scan cost on every loop and getting no result. On a host whose
only disk is a single DRAM-less NVMe (ADR-034) that saturation translated straight into
node-level damage: `iostat` `w_await` ~200 ms, `/proc/pressure/io` `avg60` ~8%+, and
the API server plus node-13's kubelet timing out (lease acquisition
`context deadline exceeded`), which was the actual trigger for a mass container
restart storm on that node.

This is a repeat, not a new failure. The file already records REL-012c (concurrent scan
storms driving etcd/apiserver latency) and a 2026-08-22 pause that was re-enabled at
`OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT=1`. That limit caps *concurrent* jobs, not the
per-job I/O — a single job still downloads a DB and extracts image layers — so lowering
it never bounded the total.

## Decision

- **Set `replicas: 0`, in Git.** ArgoCD's `selfHeal` previously reverted a manual
  `kubectl scale --replicas=0` within one reconcile cycle, letting the operator come
  back; a tracked manifest is the only thing that holds.
- **Treat CI as the vulnerability gate.** `aquasecurity/trivy-action` plus
  `scripts/check-trivy-sarif.py` already run on every PR, so images are scanned before
  they ship. Rescanning the same 160+ runtime images in-cluster added no gate that did
  not already exist — it only added I/O.
- **Re-enable only with a bounded per-job I/O profile** (shared durable cache, throttled
  layer pulls, or a job-level I/O budget), not by flipping the replicas back and
  rediscovering the wall.

## Update — 2026-10-18 (reports deleted)

The stale reports this ADR chose to leave in place were removed from the cluster.
Every `aquasecurity.github.io` report CR was deleted — `vulnerabilityreports` (129),
`configauditreports` (485), `exposedsecretreports` (208), `rbacassessmentreports` (37),
`clusterrbacassessmentreports` (128), `clusterconfigauditreports` (49), `sbomreports`
(121), `clustersbomreports` (1), `clusterinfraassessmentreports` (3),
`clustervulnerabilityreports` (1). That is ~130 MB of etcd state, the SBOM types the
bulk of it.

Reversible: this ADR's own decision is that nothing consumes the reports, so the only
thing lost is a stale snapshot; re-enabling the operator regenerates them. The SQLite
file itself does not shrink on row deletion (kine keeps `state.db` at 289 MB and its WAL
at 322 MB) — reclaiming that needs a checkpoint/vacuum or a k3s restart, left as a
separate maintenance-window action rather than risking the API server here.

## Consequences

- Host ground truth after the change: `nvme0n1` **19 → 1.1 MB/s**, load **24 → 2.9**,
  top in-VM writers now just the Minecraft JVM (~0.65 MB/s); Paper TPS back to
  20.0/19.8/19.7. The remaining watchdog headroom (ADR-056's load bar of 50) now has
  real slack instead of being consumed by one component.
- **No runtime drift detection for image vulnerabilities.** Nothing now notices that a
  long-running Pod is on an image with a CVE disclosed after it shipped. Accepted for
  now: rebuilds and PR scanning cover what ships, and the lab's reach is narrow
  (`docs/EXPOSURE.md`).
- Existing `VulnerabilityReport`/`ConfigAuditReport` objects stay in etcd (161 + 522
  already, which ADR-related comments call out as bloat). Deleting them is separate
  follow-up and not required by this ADR.
- The operator's own `ConfigMap` and PriorityClass stay in place, so re-enabling is a
  one-line `replicas` change with no other migration.
