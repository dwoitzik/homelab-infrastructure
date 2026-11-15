# Runbook: k3s minor upgrade

One Kubernetes minor per step, server first, then the agents one at a time. Why the
upgrade swaps the binary instead of running `ansible/k3s-cluster/playbooks/upgrade.yml`,
and why the drain skips node-pinned pods, is in
`docs/decisions/ADR-080-k3s-upgrade-by-binary-swap.md`.

The automated path is the nightly `k3s_auto_upgrade` Ansible role on the Proxmox host
(ADR-081), which runs the same steps with `scripts/k3s/drain-movable.py`; this runbook is
the manual procedure and the reference for what that role does.

| Node | VM | Service |
|---|---|---|
| `vm-srv-k3s-11` (10.0.20.11) | 211 | `k3s` (server, SQLite via kine) |
| `vm-srv-k3s-12` (10.0.20.12) | 212 | `k3s-agent` |
| `vm-srv-k3s-13` (10.0.20.13) | 213 | `k3s-agent` |

## 1. Prepare (no impact)

1. Pick the latest patch of the next minor from the k3s release list. Never skip a minor.
2. Read the k3s release notes for that minor and the "Urgent Upgrade Notes" and
   deprecation list in the Kubernetes changelog.
3. Check for removed APIs:
   - live: `kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis`, plus
     `max_over_time(apiserver_requested_deprecated_apis[30d])` in Prometheus;
   - repo: grep `kubernetes/` for the removed `apiVersion`s, and render the charts with
     `scripts/render-helm-applications.py --kube-version <new>`.
4. Branch, change `k3s_version` in `ansible/k3s-cluster/inventory.yml` (and
   `inventory-ha.yml`), open the PR. Merge it once the step is green.
5. Pre-fetch the binary on every node, it can take minutes from this network:
   `scripts/k3s/upgrade-node.sh <ip> <node> <k3s|k3s-agent> <version> fetch-only`.
6. Check the LVM thin pool has room for three snapshots:
   `ssh root@10.0.10.10 lvs pve/data` (snapshots grow with every write while they exist).

## 2. Server

```bash
ssh root@10.0.10.10 qm snapshot 211 pre-k3s-<minor>
ssh dw@10.0.20.11 'sudo install -d -m 700 /root/k3s-db-backup && \
  sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db \
  ".backup /root/k3s-db-backup/state-pre-<minor>.db" && \
  sudo chmod 600 /root/k3s-db-backup/*.db'
scripts/k3s/upgrade-node.sh 10.0.20.11 vm-srv-k3s-11 k3s <version>
scripts/k3s/post-upgrade-check.sh
```

The `.backup` copy holds the encrypted Secrets; it stays root-only on the VM and is
deleted at the end of the step. The server is not drained: a k3s restart leaves the
containers running.

## 3. Agents, one at a time

```bash
ssh root@10.0.10.10 qm snapshot 212 pre-k3s-<minor>
scripts/k3s/drain-movable.py vm-srv-k3s-12
scripts/k3s/upgrade-node.sh 10.0.20.12 vm-srv-k3s-12 k3s-agent <version>
kubectl uncordon vm-srv-k3s-12
scripts/k3s/post-upgrade-check.sh
```

Wait until every evicted pod is Running again before the next agent. Evicted pods pull
their images on the node they land on; a node that never ran an image pulls it from the
registry. If pulls crawl, copy the image from a node that has it over the LAN:
`ssh dw@<src> 'sudo k3s ctr -n k8s.io images export - <ref>' | ssh dw@<dst> 'sudo k3s ctr -n k8s.io images import -'`.
Do not run `crictl rmi --prune` on a node while it is drained: every image of the
evicted pods counts as unused and gets deleted.

## 4. Done criteria for the step

`scripts/k3s/post-upgrade-check.sh` shows:

- all nodes Ready on the new version, none unschedulable;
- `k3s secrets-encrypt status`: Enabled, all hashes match;
- no pod outside Running/Completed;
- every ExternalSecret `SecretSynced`;
- every ArgoCD app Synced/Healthy (annotate `argocd.argoproj.io/refresh=normal` to
  re-check stale ones);
- ingress answers through Traefik for backends on each node;
- 0 Prometheus targets down;
- both Velero BSLs Available;
- NetworkPolicy probe prints `denied_ok`, `control_reached`, `dns_ok`.

Then delete the step's snapshots (`qm delsnapshot <vmid> pre-k3s-<minor>`), the SQLite
copy and the `/usr/local/bin/k3s.prev-*` binaries, and merge the pin PR.

## 5. Rollback

- Agent: `scripts/k3s/upgrade-node.sh` keeps the old binary as
  `/usr/local/bin/k3s.prev-<old>`; move it back and restart `k3s-agent`, or
  `qm rollback <vmid> pre-k3s-<minor>`.
- Server: the datastore may already be written by the new apiserver, so a binary
  downgrade is not supported. Stop k3s, put the SQLite `.backup` back as `state.db`,
  start the old binary; or `qm rollback 211 pre-k3s-<minor>`. Either way the cluster
  loses whatever happened since the backup.
