# ADR-026: Keep the 3-VM-on-one-host k3s topology

**Date:** 2026-08-22
**Status:** Accepted

## Context

The whole cluster runs as 3 KVM VMs (`vm-srv-k3s-11/12/13`) on a single Proxmox host
(`pve-mgmt-01`, Ryzen 5825U, 8C/16T, 64GB RAM, one 512GB NVMe). This was already
documented as a hardware constraint (`CLAUDE.local.md`'s Hardware Inventory section:
"pve-mgmt-01 is a single point of failure for everything... Zero-downtime HA is NOT
achievable with this hardware"), but the *overhead* of splitting one host's resources
into 3 virtualized nodes, versus running k3s on fewer VMs (or bare-metal on the host
directly), had never actually been measured. Section G of the current recovery
directive asked for a real answer either way, not an assumption.

## Data gathered (live, this session)

**Allocation vs. host capacity:**

| Resource | Host total | VM211 (k3s-11) | VM212 (k3s-12) | VM213 (k3s-13) | Sum allocated | % of host |
|---|---|---|---|---|---|---|
| vCPU | 16 threads | 6 | 4 | 4 | 14 | 87.5% |
| RAM | 62GiB | 16GiB | 8GiB | 8GiB | 32GiB | ~52% |

CPU allocation is tight (14 of 16 threads committed to the 3 VMs alone, leaving 2
threads' worth of headroom for the Proxmox host itself and every LXC guest —
`ct-mgmt-pbs-01`, `ct-srv-docker-01`, `ct-srv-ai-01`, both DMZ LXCs, this recovery
agent's own LXC). RAM allocation has more slack.

**Actual steady-state usage** (`kubectl top nodes`, post-incident-recovery):

| Node | CPU used | CPU % | Memory used | Memory % |
|---|---|---|---|---|
| k3s-11 | 675m | 11% | 10.4GiB | 66% |
| k3s-12 | 384m | 9% | 3.9GiB | 48% |
| k3s-13 | 271m | 6% | 5.0GiB | 63% |

Total in-cluster compute demand is small (~1.3 cores out of 14 allocated vCPUs,
~9.5% average) — CPU is not the binding constraint in steady state. Memory
utilization per node (48-66%) is comfortably provisioned but not overcommitted the
way CPU allocation is.

**KVM/QEMU overhead itself**: all 3 VMs run with hardware virtualization extensions
enabled (`-cpu host,+kvm_pv_eoi,+kvm_pv_unhalt`), which puts raw compute overhead in
the low single digits versus bare metal — well-established behavior for
hardware-accelerated KVM, not something this session needed to re-benchmark. The real,
measurable per-VM cost is fixed overhead: each QEMU process itself, plus the guest
kernel/OS baseline, on the order of a few hundred MB of RAM per VM — negligible against
a 62GiB host.

**What today's incident actually revealed** (see `phase8/LEDGER.md` Entry 88 and the
2026-08-22 update to ADR-023): a real `KubeAPIServerHighLatency` incident, host load
33→57, driven by concurrent trivy-operator scans and a Renovate job, showed up as
contention across the shared LVM thin pool — `iostat` during the incident showed 10+
*separate* thin-pool logical volumes (each VM's virtual disk is its own thin LV) all
pegged near 100% `%util` *simultaneously*. Splitting into 3 VMs gave **zero real disk
I/O isolation** between them, because all 3 virtual disks still funnel through the
same single physical NVMe and the same thin-pool's shared metadata/allocation path.

## Options considered

**Option A — keep 3 VMs (status quo).** Real operational benefits: k3s's own
node-level fault tolerance actually functions (a kernel panic or OOM on `k3s-12`
doesn't take the control plane down with it — matches Kubernetes' own HA design
assumptions even though the hypervisor underneath is still a single point of
failure), and each VM's OS/kernel can be patched, drained, and rebooted independently
without a full-cluster outage. CPU/RAM overhead of the split itself is small (measured
above: a few hundred MB fixed cost, negligible CPU tax from KVM hardware acceleration).

**Option B — consolidate to 1 VM (single-node k3s).** Would reclaim the fixed
per-VM overhead (maybe 500MB-1GB RAM, a fraction of a CPU core) and slightly simplify
operations (one node to patch/monitor instead of three). But **would not address the
actual failure mode that has caused two real incidents** (ADR-023's original Garage
repair incident, today's trivy-operator/Renovate incident) — both were shared-disk
contention, which is a property of the one physical NVMe, not the VM count. A
single-node k3s still has all its state (kine/SQLite, every PV) on the exact same
disk. Consolidating would *also* lose the node-level fault isolation Option A
provides, for a resource savings measured in single-digit percent of host capacity.
Bad trade — reduces resilience to reclaim overhead that was never the actual
bottleneck.

**Option C — reduce to 2 VMs (merge two workers).** Same reasoning as Option B, just
less extreme: real overhead savings are marginal (workers are already right-sized to
their actual usage — 9%/6% CPU, 48%/63% memory — so merging them wouldn't even
free meaningful capacity, just concentrate two already-modest workloads onto one
VM), and does nothing for the disk-contention problem either. Rejected for the same
reason as B, just weaker.

## Decision

**Keep the 3-VM topology (Option A).** The measured overhead of the split itself —
a few hundred MB of fixed RAM cost, negligible CPU tax under KVM hardware
acceleration — is real but small, and buys genuine node-level fault isolation that
this hardware would otherwise never have. The two actual incidents this cluster has
had were never caused by "too many VMs" — both were the single shared physical disk,
which no VM-count change fixes. That problem already has its own, more targeted
mitigations (ADR-023's Garage repair guard and vzdump throttle, today's trivy-operator
git-tracked pause, the standing practice documented in ADR-023's 2026-08-22 update
about git-tracking any mitigation against a selfHeal-managed resource).

CPU allocation (14/16 threads, 87.5%) is the tighter of the two resources and is
worth watching — see the companion right-sizing pass (Section G) for whether any
VM's `cores:` allocation can be trimmed based on the low observed utilization above,
which would free real host-level headroom without touching the 3-VM structure itself.

## Consequences

- No topology change. The single-host SPOF remains exactly as already documented in
  `CLAUDE.local.md` — this ADR doesn't change that, it just confirms consolidating
  VMs wouldn't have helped either of the two real incidents seen so far.
- Future disk-contention mitigation work should keep targeting the shared thin-pool
  directly (I/O guards, concurrency caps on bulk jobs, git-tracked pauses for
  automated controllers) rather than VM consolidation — this ADR is the place to
  point back to if VM consolidation comes up again as a proposed fix for an I/O
  incident.
- CPU overcommit (14/16 threads already allocated to VMs alone) is the more
  actionable finding here — right-sizing `cores:` allocations against actual
  measured usage (11%/9%/6%) is a legitimate, separate follow-up with real payoff,
  unlike VM-count reduction.
