# Kyverno

Cluster policy enforcement. `policies.yml` holds three `ClusterPolicy` resources
(require-resource-limits, disallow-privileged-containers, disallow-latest-tag) that
check both containers and init containers, plus the PolicyException for
tailscale-subnet-router. The `kyverno` Application deploys the chart and this file
as two sources.

## Scope — deliberately not cluster-wide

Limits and image tags are enforced in `apps`, `database` and `security`; privileged
containers additionally in `monitoring` and `external-secrets`. Limits are not
enforced in `monitoring`. A cluster-wide PolicyReport sweep (2026-06-23) confirmed zero
violations before flipping from Audit to Enforce — but restarting Grafana
(kube-prometheus-stack chart) immediately afterward got blocked: several of that
chart's templated sidecars (`grafana-sc-dashboard`, `grafana-sc-datasources`, and
others across `monitoring`) lack resource limits by upstream chart default. Chasing
every third-party sidecar's resource values across chart upgrades is separate, larger
scope than this pass — `apps` and `database` are this repo's own hand-written
manifests, where enforcement doesn't hit that problem.

## Drift check

Background reports are disabled (etcd write load), so a running pod that violates a
policy is only caught at its next admission.
`kubernetes/system/monitoring/kyverno-policy-drift-check.yml` evaluates the same
rules against running pods every six hours and posts violations to Discord. Change
both files together.

## Controller

`application.yml` is the Kyverno Helm chart itself (admission controller), not just the
policies — this directory covers both. Deployed fail-open (`failurePolicy: Fail` would
block all API requests for up to 30s if Kyverno were ever unavailable — deliberately
avoided so a Kyverno outage can't take down the whole API server).

## Dependencies

None to bootstrap.
