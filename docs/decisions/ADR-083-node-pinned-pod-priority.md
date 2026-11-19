# ADR-083: Pods pinned to a node outrank movable pods

**Date:** 2026-11-19
**Status:** Accepted, rolling out

## Context

`local-path` volumes live on one node's disk, so the PV carries a node affinity and its
pod can only ever run there. Twenty PVs use `local-path` today: the five CNPG instances in
`database`, Vault, Grafana, Uptime Kuma, the two `pg-dump` targets, the Vault snapshot
target and ten app Deployments (Gitea, Headscale and its subnet router, Home Assistant,
Mealie, Nextcloud, Open WebUI, Scanopy, Vaultwarden).

Every pod in the cluster had the same priority (0) except CoreDNS, metrics-server and the
local-path provisioner. When all three k3s VMs came back from a snapshot rollback
(ADR-082 drill), pods were scheduled in whatever order the queue produced. Movable pods
landed on `vm-srv-k3s-12` first and used up its memory, and `postgres-synapse-1` sat
Pending for 18 hours with `1 Insufficient memory, 2 node(s) didn't match
PersistentVolume's node affinity`. The pods that filled the node could have run on
either of the other two nodes.

The six DaemonSets (metallb speaker, alloy, node-exporter, crowdsec agent, velero
node-agent, sysctl-fix) have the same problem in a milder form: they are pinned to their
node by construction, and at priority 0 they are as evictable as anything else.

Options considered:

1. **PriorityClass for pinned pods.** The scheduler preempts lower-priority pods on the
   one node a pinned pod can use; the evicted movable pods reschedule elsewhere.
2. **Descheduler.** Reacts after the fact on a timer and needs its own policy tuning;
   it does not make the scheduler place pods in the right order to begin with.
3. **Move the data to `nfs-client`.** Removes the pinning, but most of these are
   SQLite or Postgres data directories, which the REL-020 near-miss showed do not
   belong on NFS.
4. **Order the cold start in the rollback script.** Only covers the ADR-082 path, not a
   host power loss or a manual restart of all three VMs.

## Decision

Option 1, with two classes at the same value:

- `node-pinned-stateful` (1000000, `PreemptLowerPriority`) on every workload whose pods
  mount a `local-path` PVC: CNPG `Cluster.spec.priorityClassName`, chart values for
  Vault (`server.priorityClassName`) and Grafana (`grafana.priorityClassName`), the pod
  template for plain Deployments.
- `node-daemon` (1000000, `PreemptLowerPriority`) on every DaemonSet.

Equal values mean a pinned database never evicts a node agent and the other way round;
both preempt default-priority pods. `system-cluster-critical` (2000000000) and
`system-node-critical` (2000001000) stay well above, so CoreDNS, metrics-server and the
local-path provisioner cannot be preempted by either. `trivy-scan` (-1000000) stays the
first victim.

Not covered on purpose: the `nextcloud-cron` CronJob mounts `nextcloud-html` but runs
for seconds every five minutes; a high-priority Job could evict a movable pod every run
when the node is tight, and a missed run is harmless.

## Consequences

- A cold start can evict a movable pod (Traefik, ArgoCD, an app) from a full node. It
  reschedules on another node. If the whole cluster is short of memory the movable pod
  stays Pending instead of the database, which is the intended trade.
- Setting `priorityClassName` restarts each pod once. The rollout went one group per PR
  (classes, DaemonSets, apps, monitoring and Vault, databases one at a time).
- New `local-path` workloads and new DaemonSets must set the matching class.
  `kubernetes/system/infrastructure/README.md` says so next to the class definitions.
