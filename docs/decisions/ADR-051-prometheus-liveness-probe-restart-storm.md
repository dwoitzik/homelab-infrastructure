# ADR-051: Prometheus restart storm was the liveness probe killing it, not Prometheus crashing

**Status:** Accepted and applied, 2026-10-03

## Context

On 2026-10-03 `PrometheusFrequentRestarts` fired at 03:55 local and only resolved
at 11:55 — eight hours for a restart event that lasted 102 seconds. Two separate
defects were involved, and the second one was in the alert that was supposed to
report the first.

The `ntfy` history from `pve-mgmt-01` puts the sequence together:

```text
03:15  pve host: Load 38.96 (>=30)
03:37  pve host: Load 56.36 (>=30)
03:39  prometheus container terminates, exit 0
03:55  PrometheusFrequentRestarts FIRES
04:35  PBS health check: VMID 110 backup 1262h old, 9211 1034h, 9213 1033h
11:55  PrometheusFrequentRestarts RESOLVES
```

## Root cause: the chart-default liveness probe

`prometheus-kube-prometheus-stack-prometheus-0` had restarted **46 times**. The
container's `lastState` is `reason=Completed, exit=0` — a clean exit, which is
what kubelet records after it has sent SIGTERM to a container that failed its
liveness probe. Not one restart was an `OOMKill`.

The effective probe was the chart default, unmodified by this repo:

```text
periodSeconds: 5
timeoutSeconds: 3
failureThreshold: 6
```

That is three seconds to answer `/-/healthy` and thirty seconds of tolerance
before a restart. Under a host load of 38–56 on `pve-mgmt-01` — the same host
running the PBS backup that was failing in the same window — thirty seconds is
not survivable. Prometheus was not crashing; it was too slow to answer a
three-second probe and got killed for it.

Grafana in this same chart had already been given generous probe values on
2026-08-14, after a fresh Grafana pod was observed being SIGKILLed mid-migration
under load. Prometheus never got the same treatment, which is the gap this ADR
closes.

## The alert was also wrong, in a way that obscured the incident

The alert shipped in PR #819 read:

```promql
changes(process_start_time_seconds{...}[6h]) >= 2
```

with `summary: "restarted {{ $value }}x in the last hour"` and a description
saying "process starts within an hour". The expression counted **six** hours; the
text claimed one.

That mismatch explains the eight-hour page directly. A `changes(...[6h]) >= 2`
alert cannot resolve until six hours have elapsed since the second-to-last
restart counted inside the window, so it stays firing long after the flapping
stopped — and its own description told the reader the wrong window while doing
it. The alert was reporting "this happened recently", which is not what a
`critical` restart alert is for.

## Decision

- `prometheus.prometheusSpec.livenessProbe`: `periodSeconds: 15`,
  `timeoutSeconds: 10`, `failureThreshold: 12`. Three minutes of tolerance
  before a restart is considered, which clears a slow self-scrape while still
  catching a genuinely wedged container.
- `prometheus.prometheusSpec.readinessProbe`: `periodSeconds: 15`,
  `timeoutSeconds: 10`, `failureThreshold: 4` — matched to the liveness probe
  so a slow-but-alive Prometheus is not pulled out of the Service prematurely
  and then killed for it.
- Alert window `[6h]` → `[1h]`, `for: 15m` → `10m`, so the alert resolves about
  an hour after a flapping episode instead of staying pinned for the length of
  the window.
- Alert text rewritten to describe the window it actually evaluates, and to
  point at the exit code as the thing that distinguishes the two failure modes:
  exit 0 means the probe killed it, exit 137 means it was OOMKilled and the
  resource limits are the problem.

`resources.limits.cpu: 1000m` is left alone here. Nothing has been OOMKilled, so
there is no evidence to justify changing it, but CPU throttling on a
single-threaded Prometheus under a load spike is the next thing to check if
restarts continue after this change lands.

## The fix was silently inert on the first attempt, and ArgoCD reported "Synced"

The first version of this change set `prometheus.prometheusSpec.livenessProbe`,
mirroring how Grafana's probe is configured in the same chart. It merged, all CI
was green, ArgoCD reported `Synced`/`Healthy` across all 108 resources, and the
StatefulSet never changed: still `periodSeconds 5, timeoutSeconds 3,
failureThreshold 6`, `generation: 11`, restart count unmoved at 46.

The `Prometheus` CRD has no `spec.livenessProbe`. It only supports probe overrides
per container:

```yaml
spec:
  containers:
    - name: prometheus
      livenessProbe: {...}
```

A flat `spec.livenessProbe` is a valid YAML key that the structural schema prunes
away on apply. ArgoCD then compares rendered-against-applied, both sides equally
pruned, and reports no difference. Grafana is unaffected by this: the `Grafana` CRD
*does* expose `spec.livenessProbe`, which is why its 2026-08-14 values are live on
the pod while the equivalent Prometheus keys never were.

Two things this makes worth remembering:

- **"Synced" is not evidence.** The only check that caught this was reading
  `sts.spec.template` directly and comparing the numbers.
- Schema-pruning failures are silent. An unknown key under a CRD is not an apply
  error, it is a value that quietly becomes nothing.

The values are now nested under `containers[]`, verified key-by-key against the
live CRD's structural schema (and against upstream, where the same key set
appears) before applying.

## Not addressed here

The PBS health check firing in the same window is a separate problem and is not
part of this ADR. `VMID 110` at 1262h (~52 days) and `VMID 9211` at 1034h (~43
days) are not backups missed because of tonight's load spike — those guests have
not been backed up in over a month. That needs its own investigation into the
`/etc/pve/jobs.cfg` exclude list and the nightly job itself.
