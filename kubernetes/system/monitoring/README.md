# monitoring

The observability stack: kube-prometheus-stack (Prometheus + Grafana + Alertmanager),
Loki, and everything alerting/dashboards-related that doesn't belong to a specific
workload.

## Why several dashboards/scrapers look messy right now

See `docs/URL-INVENTORY.md` and the Phase 6 ADRs — Grafana's default dashboard set is
mostly kube-prometheus-stack's stock imports (some, like the AIX/macOS Node Exporter
ones, are irrelevant to this all-Linux homelab), not yet curated down to a small
useful set. Tracked as open follow-up work, not fixed as of this README.

## k3s-specific tuning (don't "correct" these back to kubeadm defaults)

`kubeControllerManager`/`kubeScheduler` are disabled in `application.yml`. k3s bundles
these into the single server binary — they're never separately-scrapable the way a
kubeadm cluster exposes them, so the chart's default ServiceMonitors for them can never
succeed and their paired critical alerts fire permanently. Found firing continuously
since 2026-06-22 in a full alert sweep; disabling is the correct fix here, not a
workaround — there's no real target to scrape on this platform.

## Blackbox exporter — standalone, not the chart's subchart

`blackbox-exporter.yml` deploys `prometheus-blackbox-exporter` standalone. The
kube-prometheus-stack chart lists it as a dependency but ArgoCD doesn't render the
sub-chart from the upstream repo — so it's deployed separately here, with scrape
configs in `application.yml` (`blackbox-http`, `blackbox-authelia-health` jobs)
pointing at this standalone Service's DNS name. Probes every public hostname in
`docs/URL-INVENTORY.md`.

## SLOs and alert routing

- `slo-rules.yml` / `slo-dashboard.yml` — 99.9% availability + p95≤2s latency
  PrometheusRules and the paired Grafana error-budget dashboard. These were deployed
  once but never actually evaluated for a while — a missing `release:
  kube-prometheus-stack` label meant Prometheus's `ruleSelector` never matched them
  (the same gap silently affected `hardware-temp-alerts.yml` too). Check that label is
  present on any new PrometheusRule added here, or it'll silently never fire.
- `alertmanager-config.yml` + `alertmanager-discord.yml` — routes alerts to Discord.
  The webhook URL comes from Vault via ExternalSecret; if Alertmanager ever goes
  quiet, check the webhook is still valid on Discord's side first (it has gone stale
  before — Discord returned "404 Unknown Webhook" for a rotated/deleted webhook while
  the URL in Vault still pointed at it).
- Per-domain alert rules split into their own files: `cert-manager-alerts.yml`,
  `control-plane-alerts.yml`, `hardware-temp-alerts.yml`, `postgres-alerts.yml`,
  `storage-capacity-alerts.yml`, `velero-alerts.yml` — one file per concern rather than
  one giant rules file.

## Loki

`loki.yml` — log aggregation, local filesystem storage (not S3-backed — logs are
lower-value than metrics/traces here). `loki-dashboard.yml` provisions its Grafana
dashboard as code.

## Dependencies

Vault + ExternalSecrets (Discord webhook, `external-secret.yml`), CloudNativePG (for
`postgres-monitoring.yml`'s exporter sidecar pattern).
