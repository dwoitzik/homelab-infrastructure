# ADR-020: Grafana dashboard curation — home page fixed now, full re-curation deferred

**Date:** 2026-08-14
**Status:** Accepted

## Context

The operator's own assessment of this homelab's observability stack, verbatim from
`phase6/BRIEFING-V2.md`: Grafana is "**potthässlich**" (butt-ugly). Investigating
concretely: `GET /api/search?type=dash-db` against the live instance returns 29
dashboards. Exactly 1 (`SLO Error Budget`, this repo's own hand-built dashboard) is
genuinely useful day-to-day. The rest are `kube-prometheus-stack`'s stock bundled
imports — several with zero relevance to this specific homelab (`Node Exporter / AIX`,
`Node Exporter / MacOS` on an all-Debian-Linux cluster) and several more that are
generically useful but not something anyone actually opens routinely (per-namespace
Kubernetes Compute/Networking breakdowns ×6, CoreDNS, etcd).

The brief's own ask: "A small number of dashboards that are actually useful beats
thirty imported ones nobody opens... a real overview dashboard as the landing page."

## What was actually checked before deciding scope

Before assuming a quick Helm-values fix existed, checked: is there a supported way to
exclude specific default dashboards from `kube-prometheus-stack` while keeping the
rest? Confirmed via an **open, unresolved upstream GitHub issue**
(`prometheus-community/helm-charts#3763`, "Allow disabling some of the default grafana
dashboards") that this genuinely isn't supported — there is no per-dashboard toggle.
The only chart-level lever is `grafana.defaultDashboardsEnabled`, which is all-or-
nothing for the entire bundled set.

## Decision

Split into two pieces, deliberately handled differently:

1. **Landing page — fixed now.** `grafana.ini`'s `dashboards.default_home_dashboard_path`
   now points at the SLO Error Budget dashboard instead of Grafana's own generic
   default. Whoever opens Grafana lands on the one dashboard actually built for this
   homelab, not an empty "welcome" screen or an arbitrary stock import.
2. **Full dashboard-set reduction — deferred, not attempted this pass.** Actually
   solving "30 dashboards nobody opens" properly means `defaultDashboardsEnabled:
   false` (drop the entire stock set) plus hand-picking and provisioning a real
   replacement set via `grafana.dashboards` (pulling specific `gnetId`s from
   grafana.com, or writing custom JSON — the same pattern already used for
   `node-exporter-full`/`proxmox-pve`/`proxmox-summary` in this repo). That is a
   real, separate body of work: selecting which ~5-8 dashboards actually earn a place,
   verifying each renders correctly with this cluster's real Prometheus data, and
   confirming nothing currently useful (even if imperfect) gets dropped by accident.

## Reasons

- **Landing-page fix is low-risk, high-value, fully achievable today** — a single
  config key, no risk of removing a dashboard someone might still want.
- **Full re-curation is exactly the kind of change that shouldn't be rushed.** Silently
  dropping `defaultDashboardsEnabled` removes dashboards wholesale, including ones that
  might be genuinely useful during an actual incident even if nobody opens them on a
  quiet day (e.g. `Kubernetes / Persistent Volumes` during a disk-pressure event). That
  judgment call deserves its own deliberate pass, not a rushed decision bundled into an
  unrelated fix.
- **No clean partial solution exists to fall back on.** Given #3763 confirms there's no
  built-in per-dashboard exclusion, the only paths are "accept the stock set" or "replace
  it wholesale" — there's no safe middle ground to reach for under time pressure.

## Trade-offs (accepted)

- The AIX/macOS Node Exporter dashboards (and other stock clutter) remain visible in
  Grafana's dashboard list until the full re-curation happens. Cosmetic, not functional
  — they simply don't get used, same as before this ADR.
- Testing the home-dashboard-path change live surfaced a real, separate bug (Grafana's
  default liveness-probe timing vs. actual SQLite migration time on a fresh pod) —
  fixed in the same change, documented in its own commit, not a scope-creep addition to
  this ADR's actual decision.

## Consequences

- `kubernetes/system/monitoring/application.yml`: `grafana.ini`'s
  `dashboards.default_home_dashboard_path` set to the SLO Error Budget dashboard's file
  path.
- Full dashboard-set curation is tracked as real, named follow-up work: pick the actual
  useful set (`SLO Error Budget`, `Node Exporter Full`, `Kubernetes / Compute Resources
  / Cluster`, `Alertmanager / Overview`, `CloudNativePG`, `Loki: Kubernetes Logs` are
  reasonable starting candidates, not a final decision), set
  `grafana.defaultDashboardsEnabled: false`, provision the chosen set via
  `grafana.dashboards`, and verify each one renders correctly against this cluster's
  live data before considering it done.
