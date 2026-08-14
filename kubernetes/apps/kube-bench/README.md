# kube-bench

CIS Kubernetes Benchmark scanner — runs as a Job, checks the cluster's own config
against the CIS baseline, reports findings.

## Storage

None — reads live cluster/node state, produces a report, exits. No persistence needed;
re-running it costs nothing but the scan time itself.
