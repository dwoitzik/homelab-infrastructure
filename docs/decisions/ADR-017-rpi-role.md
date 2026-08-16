# ADR-017: Raspberry Pi Role — DNS/Edge Only, Not a k3s Cluster Member

**Date:** 2026-08-13
**Status:** Accepted

## Context

Phase 3 of the recovery brief asks directly: "Should the Pis be control plane, workers, or
something else — what's their SD card / boot medium doing to their lifespan?"

Current/historical state (per BRIEFING.md handoff and Phase 0 findings): both RPi 4Bs
(`rpi1`/`rpi2`, 8GB RAM, SD-card boot) run AdGuard Home + Unbound (the whole network's DNS
path) plus light Docker workloads. k3s-agent is installed on both but disabled — a dormant,
half-finished integration, not an active one.

ADR-014 already examined and rejected using the Pis as etcd members (Option B), for two
independent reasons: SD-card write fragility versus etcd's fsync-heavy raft log, and mixing
a critical-path responsibility (DNS) with k8s blast radius on the same small boxes. ADR-015
(this same session) removes etcd from the cluster entirely, which resolves the first
objection structurally — there is no longer an etcd role to consider putting on the Pis.
But ADR-014's second objection (blast-radius mixing) was never etcd-specific — it applies
equally to using the Pis as plain k3s **agents** (workers), which is the option ADR-014
didn't directly rule on because it was only evaluating etcd membership.

This ADR closes that gap directly.

## Decision

Raspberry Pis stay **out of the k3s cluster entirely** — no control-plane role, no agent
(worker) role. Their role remains DNS (AdGuard + Unbound) and light, non-critical Docker
workloads only. The dormant `k3s-agent` installation on both Pis should be removed
(uninstalled), not merely left disabled, during Phase 4 — a disabled-but-installed agent is
exactly the kind of half-finished state this recovery exists to clean up, and an unused
install is attack surface and confusion for no benefit.

## Reasons

- **Blast radius, independent of etcd.** DNS is this network's single most critical shared
  dependency — every other host, including the k3s VMs and this recovery agent's own SSH
  access, resolves through it. A k3s agent problem (OOM, a bad pod, a kubelet bug) on a Pi
  that's also running AdGuard/Unbound risks degrading DNS network-wide. This was ADR-014's
  reasoning for rejecting Pi-as-etcd-member and it applies with equal force to
  Pi-as-plain-worker — nothing about being agent-only (vs. server) changes the
  shared-blast-radius argument. ADR-014 didn't fully generalize this, and this ADR corrects
  that gap explicitly.
- **SD-card write fragility is real even without etcd.** k3s agents still write kubelet
  state, container logs, and image layers locally — meaningfully less write pressure than
  running etcd, but not zero, and `CLAUDE.local.md` already treats RPi SD cards as a hard
  guardrail ("write-fragile... treat RPi nodes as disposable"), not a soft preference. There
  is no USB-SSD boot in place for either Pi today — that would be a real prerequisite
  project (per ADR-014's own note on Option B), not a config flag, and hasn't been done.
- **No compute need.** The two k3s VM workers (`vm-srv-k3s-12`/`-13`) already provide worker
  capacity on the host's own fast local storage. Adding the Pis as workers doesn't relieve
  any actual resource pressure — it just adds two low-powered, high-latency, write-fragile
  nodes to the scheduler's pool for marginal benefit.
- **Simplicity matches the brief's own target state.** `CLAUDE.local.md`: "Target recovery,
  not HA... do not pretend otherwise." Keeping the Pis single-purpose (DNS) is the simpler,
  more legible design and avoids a second critical-path coupling for no demonstrated need.

## Trade-offs

- Two Pis' worth of ARM compute (8GB RAM each) goes unused for k8s workloads. Given the
  cluster's actual workload profile (a homelab app set, not a resource-constrained one —
  see ADR-015's context on scale), this is an acceptable amount of idle capacity in exchange
  for not coupling DNS to k8s stability.
- If the k3s VM workers' capacity is ever genuinely insufficient, this ADR would need
  revisiting alongside an actual USB-SSD boot migration for the Pis — not before.

## Consequences

- Phase 4: uninstall `k3s-agent` from both Pis (Ansible `rpi_nodes` group) rather than
  leaving it dormant-and-disabled.
- `ansible/inventory.ini`'s `rpi_nodes` group role description should be updated to state
  DNS/edge-only explicitly, so a future session doesn't rediscover "installed but disabled"
  and wonder if it was meant to be finished.
- No change to current DNS architecture (AdGuard primary/replica + Unbound upstream) —
  out of scope for this ADR.

## How to reverse

If Pi compute is ever actually needed for k8s workloads: (1) migrate both Pis to USB-SSD
boot first (documented prerequisite, not skippable per ADR-014's own conclusion on this
exact point), (2) confirm a multi-night stable baseline on the new boot medium, (3) install
k3s-agent fresh and join as workers only (never etcd/server — SQLite per ADR-015 doesn't
support multi-server anyway), (4) keep DNS on a NetworkPolicy/resource-limit boundary
separate from the new k8s workload if at all possible, to preserve some of the blast-radius
isolation this ADR is choosing today.
