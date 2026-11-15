# host-agents

Namespace for workloads that need host-level access by design and so cannot pass Pod
Security `baseline`: kube-bench (hostPID, read-only hostPath mounts of the kubelet
directories and `/proc` for the CIS checks).

`enforce: privileged`, with `baseline` as audit/warn so anything new still shows up.
Keeping these here is what lets `apps` enforce `baseline`.

NetworkPolicies: default-deny ingress and egress, with DNS and the apiserver allowed.
