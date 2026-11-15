# monitoring

The observability stack: kube-prometheus-stack (Prometheus + Grafana + Alertmanager),
Loki, and everything alerting/dashboards-related that doesn't belong to a specific
workload.

## Why several dashboards/scrapers look messy right now

See the Phase 6 ADRs — Grafana's default dashboard set is
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
pointing at this standalone Service's DNS name. Probes every public hostname on the
ADR-033 allowlist, plus in-cluster health checks for Authelia and Vaultwarden (by
ClusterIP) and Jellyfin (`/health`) and Nextcloud (`status.php` with the trusted Host
header, failing on maintenance mode), whose targets Prometheus discovers from the
Service endpoints. The pod resolves through public DNS only, so in-cluster targets are
never addressed by Service name.

## Extra scrape targets

`scrape-targets.yml` holds PodMonitors for components whose charts ship none: Traefik
(`:9100/metrics`) and Garage (admin port `:3903/metrics`, open while
`admin.metrics_token` is unset).

## SLOs and alert routing

- `slo-rules.yml` / `slo-dashboard.yml` — 99.9% availability (blackbox `probe_success`)
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
  `storage-capacity-alerts.yml`, `velero-alerts.yml`, `rybbit-alerts.yml` — one file per
  concern rather than one giant rules file.

## Loki

`loki.yml` — Loki (single binary, chunks and index in the Garage `loki-data` bucket,
30-day retention) and Grafana Alloy, the DaemonSet that ships pod logs. Alloy tails
`/var/log/pods` on each node with the same labels the retired Promtail chart produced
(`namespace`, `pod`, `container`, `app`, `job` = `namespace/app`, `instance`,
`component`, `node_name`, `stream`, `filename`), so existing LogQL, dashboards and
alerts work unchanged. Read positions live on the node (`/var/lib/alloy`), so a
restart neither re-sends nor skips lines. Hosts outside the cluster still ship with
the Docker Promtail from the Ansible `monitoring_agent` role. `loki-dashboard.yml`
provisions the Grafana dashboard as code.

## Dependencies

Vault + ExternalSecrets (Discord webhook, `external-secret.yml`), CloudNativePG (for
`postgres-monitoring.yml`'s exporter sidecar pattern).
