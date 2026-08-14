# Trivy Operator

Continuous vulnerability/misconfiguration scanning for cluster workloads — generates
`VulnerabilityReport`/`ConfigAuditReport` CRDs automatically as pods run.

## Storage

None — reports are Kubernetes resources (etcd/SQLite-backed by the cluster's own
control plane), not a separate PVC. Nothing app-specific to restore; re-apply the
manifests and it resumes scanning.
