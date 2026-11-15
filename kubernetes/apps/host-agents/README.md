# host-agents

Namespace for workloads that need host-level access by design and so cannot pass Pod
Security `baseline`: kube-bench (hostPID, read-only hostPath mounts of the kubelet
directories and `/proc` for the CIS checks) and the Scanopy SRV daemon (hostNetwork plus
NET_RAW/NET_ADMIN for ARP and port discovery, `kubernetes/apps/scanopy/`), and the
Tailscale subnet router / exit node (privileged, `/dev/net/tun`,
`kubernetes/apps/headscale/subnet-router.yml`).

`enforce: privileged`, with `baseline` as audit/warn so anything new still shows up.
Keeping these here is what lets `apps` enforce `baseline`.

NetworkPolicies: default-deny ingress and egress, with DNS and the apiserver allowed, plus
the subnet router's egress (Headscale control via Traefik, 80/443 and UDP to the internet,
the routed 10.0.20.0/24).

Host-network pods here reach pods on other nodes from the node's `flannel.1` address
(10.42.x.0), not from a pod IP, so the receiving namespace has to allow that by ipBlock
(see `allow-scanopy-daemon-from-host-agents` in `kubernetes/apps/network-policies.yml`).
