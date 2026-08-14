# Kyverno

Cluster policy enforcement — currently two `ClusterPolicy` resources in
`policies.yml`: require-resource-limits and disallow-latest-tag.

## Scope — deliberately not cluster-wide

Both policies are `Enforce` mode but scoped to the `apps` and `database` namespaces
only, not `monitoring`. A cluster-wide PolicyReport sweep (2026-06-23) confirmed zero
violations before flipping from Audit to Enforce — but restarting Grafana
(kube-prometheus-stack chart) immediately afterward got blocked: several of that
chart's templated sidecars (`grafana-sc-dashboard`, `grafana-sc-datasources`, and
others across `monitoring`) lack resource limits by upstream chart default. Chasing
every third-party sidecar's resource values across chart upgrades is separate, larger
scope than this pass — `apps` and `database` are this repo's own hand-written
manifests, where enforcement doesn't hit that problem.

## Controller

`application.yml` is the Kyverno Helm chart itself (admission controller), not just the
policies — this directory covers both. Deployed fail-open (`failurePolicy: Fail` would
block all API requests for up to 30s if Kyverno were ever unavailable — deliberately
avoided so a Kyverno outage can't take down the whole API server).

## Dependencies

None to bootstrap.
