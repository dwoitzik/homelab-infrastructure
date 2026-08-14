# Tempo

Distributed tracing backend (Grafana's own tracing product). Local storage backend
(not object-storage-backed) — traces are ephemeral debugging data, not something this
homelab needs long-term retention or Velero backup for. Deployed via the official
Grafana Helm chart.

## Dependencies

None to bootstrap. Consumed via Grafana's Explore view when tracing is wired into an
app (not universal across every service in this cluster).
