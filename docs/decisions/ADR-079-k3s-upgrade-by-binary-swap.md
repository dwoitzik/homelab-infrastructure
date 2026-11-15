# ADR-079: Upgrade k3s by swapping the binary, drain only movable pods

**Date:** 2026-11-15
**Status:** Accepted and applied (k3s v1.31.12 to v1.34.13, one minor per step)

## Context

The cluster ran k3s v1.31.12, an end-of-life Kubernetes minor, and several platform
upgrades (CloudNativePG 1.30, cert-manager 1.21) need 1.33 or 1.34. The repo vendors
`k3s-io/k3s-ansible` under `ansible/k3s-cluster/`, whose `playbooks/upgrade.yml` is the
obvious tool. Reading its `k3s_upgrade` role against the live nodes showed three
problems for this cluster:

- It rewrites `/etc/rancher/k3s/config.yaml` (mode 0644) on the server and adds the
  cluster token to it, which the server never needed and which would make the token
  world-readable on the VM.
- On agents it runs `/usr/local/bin/k3s-install.sh`, which only exists on the server,
  and passes the short token form instead of the full `K10...` token the agents use
  today, which drops the CA hash pinning.
- It upgrades both agents in parallel and does not drain.

`kubectl drain` has its own problem here: about a dozen pods are pinned to one node
(local-path PVs, a hostname `nodeSelector`). They cannot reschedule, so evicting them
only turns an agent restart, which running containers survive, into an outage until the
node is uncordoned. Draining `vm-srv-k3s-12` that way during the 1.32 step took
Nextcloud down (its Postgres and Redis are pinned there), and several PDBs on
single-instance pods make a plain drain hang until its timeout.

## Decision

- Upgrade each node by replacing `/usr/local/bin/k3s` with the release binary after
  checking the release sha256, then restarting the service
  (`scripts/k3s/upgrade-node.sh`). Units, `config.yaml` and agent env files stay
  untouched, so `secrets-encryption`, `egress-selector-mode` and `resolv-conf` survive.
  The pin in `ansible/k3s-cluster/inventory.yml` is still the source of truth: the
  `k3s_server`/`k3s_agent` roles install exactly that version on a rebuilt node.
- One minor per step, server first, agents one at a time, with a Proxmox snapshot of the
  node and an SQLite `.backup` of `state.db` before the server; delete both once the
  step is green.
- Drain agents with `scripts/k3s/drain-movable.py`: cordon, evict through the Eviction
  API (PDBs hold), and leave node-pinned pods running.
- Validate every node with `scripts/k3s/post-upgrade-check.sh`.

Procedure: `docs/runbooks/k3s-upgrade.md`.

## Alternatives considered

- **Fix the vendored `k3s_upgrade` role.** Possible, but it is upstream code that would
  drift from `k3s-ansible`, and the binary swap is the upgrade path the k3s docs
  describe for manual upgrades.
- **system-upgrade-controller.** The roadmap's long-term target, with Plans that
  Renovate bumps. It needs the same drain policy decision and its own CRDs and RBAC;
  left as a separate roadmap item.

## Consequences

- An upgrade is three commands per node, and rollback for an agent is the kept
  `k3s.prev-<version>` binary.
- Pinned pods take the kubelet restart in place; their services blip for seconds
  instead of staying down for the length of the drain.
- Images of evicted pods are pulled on the nodes they land on. Downloads from GitHub and
  registries are slow from this network, so pre-fetch the binary and expect pods to take
  minutes to come back, or copy images between nodes with `ctr export`/`import`.
