# ADR-037: Host Memory Headroom — Lower ZFS ARC, Raise k3s VM Balloon Floors

**Date:** 2026-08-29
**Status:** Accepted and applied (live + codified).

## Context

`vm-srv-k3s-11` wedged twice in one day. The first incident (root-caused and
planned for in ADR-036) concentrated most of the cluster's NFS-backed/
storage-less workload onto this node through pure scheduling inertia. While
implementing ADR-036's fix, the same node wedged again — `kubectl`
unreachable (up to a 45s raw TCP dial timeout, not even a TLS handshake
reached), the QEMU guest agent timing out, direct SSH timing out during the
banner exchange — while the QEMU process itself stayed alive
(`qm status 211` eventually returned `running`). Same asymmetric
hypervisor-alive/guest-wedged signature as the original incident.

**This time the trigger was different, and more fundamental than workload
placement.** Live investigation found:

- All 3 k3s VMs were balloon-deflated well below their Terraform-declared
  `dedicated` ceiling: `vm-srv-k3s-11` at ~8.4 of 16 GB, `vm-srv-k3s-12` at
  ~6.3 of 8 GB, `vm-srv-k3s-13` at ~4.3 of 8 GB (worst-squeezed, major page
  faults in the hundreds of millions — chronic, not new that day).
- The host itself was genuinely memory-short: `free -m` showed ~4.5 GB free
  out of 62 GB, with **host swap actively in use** (5.7 of 8 GB).
- LXCs were ruled out as the cause — real cgroup usage across all 9 running
  CTs was ~12.6 GB, far under their 57.5 GB soft ceiling.
- The actual cause: `scripts/check-host-memory-overcommit.py`'s hard gate
  assumed ZFS ARC was capped at 4 GB (a stale 2026-08-05 measurement). Live
  `/proc/spl/kstat/zfs/arcstats` showed `c_max=16 GiB`, matching
  `pve_power_zfs_arc_max_bytes` (set 2026-07-04, REL-037) — that value had
  since actually taken effect on the host, and the guard was never updated
  to match. It was reporting 16 GB more headroom than actually existed.

Once `vm-srv-k3s-11`'s kubelet was starved enough, its PLEG (Pod Lifecycle
Event Generator) stalled (`pleg was last seen active 14m ago`), which is
what actually made the apiserver unreachable — not a crash, a kubelet that
couldn't service requests fast enough under real memory pressure.

## Decision

Two changes, applied together because neither is safe alone:

1. **Lower `zfs_arc_max` from 16 GiB to 8 GiB** (`ansible/roles/pve_power`).
   ARC was quietly holding ~13 GB of real host RAM that could otherwise
   relieve VM ballooning. 8 GiB is a deliberate deviation below the
   generally-recommended 12-16 GiB range for a 64 GB host — justified here
   because this host runs 3 latency-sensitive k3s VMs (one of them the sole
   apiserver) rather than a typical ZFS storage-workload profile, where a
   larger cache matters more than guest memory headroom.
2. **Raise the k3s VMs' balloon floors** (`floating` in
   `terraform/stacks/proxmox/vm.tf`), made safe by the RAM the ARC cut
   freed:
   - `vm-srv-k3s-11`: 8192 → 16384 (== `dedicated`, ballooning effectively
     disabled). This is the sole control-plane/apiserver node — exactly the
     "database/control-plane workload" case where ballooning is broadly not
     recommended, because an inflate/deflate cycle mid-operation is a risk
     this specific node can't absorb (see Verification for the applicable
     research).
   - `vm-srv-k3s-12`: 4096 → 7168. Raised, not fully disabled — a worker,
     less latency-critical than the control-plane node, so some genuine
     ballooning headroom is kept for the host.
   - `vm-srv-k3s-13`: 4096 → 6144. Same reasoning as `-12`; this was the
     worst-squeezed of the 3 (worth relieving the most), still short of a
     full disable.

Deliberately **not** done: fully disabling ballooning on all 3 VMs at once.
Doing that without first freeing real host RAM would trade a graceful guest
squeeze for a real host-level OOM risk — worse, on a host with zero
failover (`CLAUDE.local.md`). Sequencing matters: free real headroom first
(ARC), then spend it (raised floors).

## Verification

- **Live, immediate, measured effect from the ARC cut alone**: `free -m`
  went from ~4.2 GB free / 5.7 GB swap-in-use to ~9.4 GB free within
  seconds of the sysfs write, before any balloon change was made.
- **`vm-srv-k3s-11` recovered live during this investigation**: as its
  balloon actual climbed toward the new 16384 floor, `major_page_faults`
  growth (which had been climbing steeply — 2.4M to 5.5M across the
  incident) flattened out, disk latency on its own LVM-thin device (dm-9)
  dropped from a 180-220ms r_await range down to ~6.5ms, and `kubectl get
  nodes` — unreachable for the entire incident up to that point — started
  responding. The node itself flipped from `NotReady` (`PLEG is not
  healthy`) to `Ready` within the same observation window, confirmed twice.
- **Corrected hard-gate math**: VM `dedicated` sum unchanged (32 GB, this
  ADR only touches `floating`/ARC, not ceilings) + 8 GB ARC + 6 GB host
  reserve = 46 GB against the existing 58 GB ceiling — a genuine 12 GB
  margin, better than either the false pre-incident 42 GB reading or the
  honest-but-tight 54 GB reading after just correcting the ARC constant
  without lowering it.
- **External research** (not just internal reasoning) on both mechanisms
  confirms this is a known, named failure mode, not a one-off:
  ballooning-induced guest thrashing on latency-sensitive/database/
  control-plane VMs is a documented Proxmox/KVM gotcha with "set the
  balloon minimum equal to dedicated for these workloads" as the standard
  mitigation ([Vormox](https://vormox.com/blog/how-memory-ballooning-works-in-proxmox-ve-and-when-to-disable-it),
  [credativ](https://www.credativ.de/en/blog/credativ-inside/evaluate-ksm-and-ballooning-features-in-proxmox-ve/)),
  and 12-16 GiB is the commonly-cited ARC range for a 64 GB Proxmox host,
  with the same sources noting a smaller cap is appropriate when guests
  don't need the host to double as their cache tier
  ([Klara Systems](https://klarasystems.com/articles/arc-and-l2arc-sizing-for-proxmox/)).

## Trade-offs (accepted)

- ARC hit rate for PBS/archive-pool reads (Jellyfin media, backups) will be
  lower with an 8 GiB cap than 16 GiB. Accepted: this host's ZFS pool
  serves large sequential media/backup reads (`CLAUDE.local.md`), which
  tolerate a smaller cache far better than a starved apiserver tolerates
  memory pressure.
- `vm-srv-k3s-11` no longer participates in ballooning at all — if host
  memory pressure spikes again, the host has one less pressure-relief valve
  for this specific 16 GB reservation. Accepted because this is the sole
  control-plane node and the one that's wedged twice; the ARC cut is what
  makes this safe rather than reckless.
- `vm-srv-k3s-12`/`-13` still balloon, just less aggressively — some
  residual thrash risk remains for those under a severe pressure spike.
  Accepted as a deliberate middle ground (see Decision) rather than
  removing the host's only remaining pressure valve entirely.

## Consequences

- `scripts/check-host-memory-overcommit.py`'s `ZFS_ARC_MAX_GB` constant
  updated to 8 (was corrected to 16 earlier the same day in PR #616 after
  finding it stale at 4 — this ADR supersedes that value with the new real
  one; #616 should be closed without merging rather than merged and
  immediately re-corrected).
- `ansible/roles/pve_power` gained a live-apply task for `zfs_arc_max`
  (mirroring the existing pattern for `zfs_vdev_async_write_max_active`) —
  previously this value only took effect on next boot.
- Live changes (sysfs ARC write, 3× `qm set --balloon`) were applied ahead
  of the corresponding code changes given the live incident this ADR
  responds to; `terraform/stacks/proxmox/vm.tf`'s `floating` values and the
  Ansible default now match what's actually running, so a future Atlantis
  plan should show no drift from this ADR's changes specifically.
- If a future measured workload profile shows 8 GiB ARC is too small
  (sub-80% hit rate sustained, per the cited sizing guidance), revisit with
  the same evidence bar this ADR was held to, not preemptively.
