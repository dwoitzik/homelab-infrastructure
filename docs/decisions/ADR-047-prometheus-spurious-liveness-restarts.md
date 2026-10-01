# ADR-047: Prometheus was killing itself via an over-tight liveness probe, not a real crash

**Status:** Accepted and applied, 2026-10-01

## Context

Prometheus container restart counts in this cluster are far above zero: 43 on the
StatefulSet's only pod, with 36 count jumps inside a single week. The same churn is
visible across the monitoring stack (`promtail` 170, `node-exporter` 156,
`kube-state-metrics` 79), so on first pass it read as a cluster-wide stability
problem rather than something specific to Prometheus.

The behaviour itself was innocuous and self-limiting. Each restart took the pod
`0/2` briefly and then recovered; Prometheus kept serving. What made it worth
chasing is that a restart loop of this shape hides real outages. Prometheus is the
thing that would notice a real failure, and it was busy restarting itself 1-3 times
a day while doing so.

## What ruled things out

The cheap explanations were checked and eliminated before anything was changed:

- **Not an OOM kill.** Live `lastState.terminated` reports `reason: Completed`,
  `exitCode: 0`, not `OOMKilled`. Memory stays well inside the 2Gi limit.
- **Not a pod recreation.** `config-reloader` inside the same pod has been running
  since 2026-09-03 with zero restarts. A deleted and recreated pod would have reset
  that container too.
- **Not a rollout.** No pod events, no ArgoCD sync of the Prometheus stack, no
  running StatefulSet revision, no config checksum annotation. `currentRevision` and
  `updateRevision` are identical.
- **Not node pressure.** No `MemoryPressure`/`DiskPressure`/`PIDPressure` condition
  on any node, no evictions.
- **Not CPU throttling.** `container_cpu_cfs_throttled_seconds_total` peaks around
  0.05-0.28 per window across most restart timestamps, and only a few events exceed
  0.74. It does not track the restart times.
- **Not external configuration.** `config-reloader` logged only config reloads (8 in
  28 days) and no restarts, which does not line up with 43.

The operator's own logs contained no restart messages, and the previous container's
log is explicit about the mechanism:

```text
Received an OS signal, exiting gracefully... signal=terminated
reason=Completed  exitCode=0
```

`Completed` with exit code 0 plus a received SIGTERM means the process did not crash
and did not run out of memory. Something asked it politely to stop, and it
complied. That rules out a crash and points at an external termination decision.

## What was actually wrong

The liveness probe was the decision-maker. Live from the running pod:

```yaml
livenessProbe: timeoutSeconds=3  periodSeconds=5  failureThreshold=6
```

That gives up after roughly 30 seconds of unresponsiveness
(6 failures x 5s period, 3s budget each). When kubelet decides that budget is
exceeded it sends SIGTERM. Prometheus traps SIGTERM, shuts down gracefully, exits 0
— which is exactly the observed signature, in exactly the order observed:

1. Prometheus stalls (compaction, a large query, scrape backlog).
2. `/-/healthy` fails to answer within 3s, six times in a row, ~30s total.
3. kubelet sends SIGTERM.
4. Prometheus exits gracefully, `reason=Completed`, `exitCode=0`.
5. Container restarts in place, `restartCount++`, pod goes `0/2`, then recovers.

The correlation between step 1 and step 5 is what makes this conclusive rather than
merely plausible. Checking each of the 36 restart timestamps in the 10 minutes before
it, using Prometheus' own self-scrape as the witness:

- **26 of 36 restarts** were preceded by the self-scrape reaching its timeout with
  `up=0` — Prometheus failing to scrape *itself*.
- Observed peak self-scrape durations before restarts include 10.01s (exactly the
  10s scrape timeout), 19.24s, 30.42s, 40.77s, 82.06s and 97.59s.
- Those slow scrapes are genuinely rare: only **0.5% of the 20,162 self-scrape
  samples** in the same 7-day window are at or above 9.5s. Baseline median is 0.01s,
  p95 is 0.20s.

So the timeouts do not represent a slow background condition. They cluster tightly
on the restart timestamps. Prometheus was being killed exactly when it was slow, and
the remaining 10 restarts are the same mechanism at lower severity: peaks of
1.1-6.7s there are slow enough to miss a 3s probe budget without tripping the 10s
scrape timeout.

The 30-second kill budget is simply shorter than Prometheus's normal worst-case
stall. TSDB compaction and rule evaluation legitimately block the HTTP handler for
tens of seconds; the observed 97s is pathological, but 10-40s is routine for a
30-day/12GiB TSDB on this hardware.

## Decision

Relax the Prometheus liveness probe via `prometheusSpec.livenessProbe`:

| Setting | Operator default | New value |
| --- | --- | --- |
| `timeoutSeconds` | 3 | 10 |
| `periodSeconds` | 5 | 15 |
| `failureThreshold` | 6 | 14 |
| Kill budget | ~30s | ~3.5 min |

`timeoutSeconds` alone does most of the work. A stalled Prometheus still gets a full
10s to answer before a failure is even recorded, which covers the compaction window
in the observed data. The `periodSeconds`/`failureThreshold` increase is
deliberately secondary, so the probe stays responsive to a genuine wedge while
giving a slow-but-alive process room.

The CPU limit (`limits.cpu: 1000m`) is deliberately left alone. Throttling does not
correlate with the restarts, so raising it would be treating a symptom the evidence
does not implicate.

### What this costs, stated plainly

A genuinely wedged Prometheus now takes roughly 3.5 minutes to be replaced by kubelet
instead of 30 seconds. That is the real tradeoff and it should not be waved away. It
is acceptable here because **the readiness probe is unchanged**: a wedged Prometheus
immediately reports not-ready and stops being scraped as a live target, so alerting
on a stalled Prometheus is not delayed by this change. Only the automatic container
replacement is slower.

## Alternatives rejected

- **Disable the liveness probe entirely.** Common advice, and it does remove the
  restart loop, but it also removes kubelet's ability to recover a wedged process.
  Given the readiness probe already surfaces the condition to alerting, relaxing
  the thresholds keeps that safety net while still fixing the false kills.
- **Raise the CPU limit.** Not supported by the data — throttling does not track
  restart timestamps.
- **Reduce compaction pressure** (shorter retention, more scrape headroom). This
  reduces stall frequency but does not change the fact that the kill budget is
  shorter than a normal compaction. Worth revisiting separately under the load
  investigation, but it is not a fix for this bug.

## Consequences

- Expected outcome: the restart count on `prometheus-...-0` stops climbing during
  compaction-heavy windows. The counter will not reset on its own, so verification
  is "no new increments", not "returns to 0".
- The `promtail`, `node-exporter` and `kube-state-metrics` churn is **not** fixed by
  this and remains open. Their probes were not investigated here.
- A future Prometheus stall should now be visible as a scrape gap rather than being
  silently papered over by a restart, which is the intended signal behaviour.
