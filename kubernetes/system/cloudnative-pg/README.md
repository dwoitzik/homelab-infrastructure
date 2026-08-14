# CloudNativePG (CNPG)

Postgres operator — every Postgres instance in this cluster (Authelia, n8n, Matrix
Synapse, and others under `kubernetes/system/postgres/`) is a CNPG `Cluster` resource,
not a hand-rolled StatefulSet. Deployed via the official Helm chart.

## Notes

Tolerates the control-plane taint (`node-role.kubernetes.io/control-plane`) — this is
a single-server k3s cluster (ADR-014/ADR-015), so workloads need to be able to schedule
onto the one server node, not just the two agent-only workers. Prometheus
PodMonitor + Grafana dashboard enabled by default.

## How to restore

Operator itself holds no cluster data — re-apply, then each `Cluster` resource under
`kubernetes/system/postgres/` recovers its own data from its backup config (see that
directory's README).

## Dependencies

None to bootstrap. Every Postgres-backed app depends on this.
