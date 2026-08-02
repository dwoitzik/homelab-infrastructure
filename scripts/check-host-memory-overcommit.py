#!/usr/bin/env python3
"""REL-035 regression guard -- two-tier model (REL-035b rework, 2026-07-07).

Two different RAM physics live in terraform/stacks/proxmox/{vm,lxc}.tf and
must not be summed together:

  - VM `dedicated` (vm.tf): Proxmox pre-allocates this as real qemu process
    memory on the host the moment the VM starts. This IS a host reservation.
  - LXC `dedicated` (lxc.tf): a cgroup memory.max -- a soft ceiling the kernel
    enforces only if the CT actually tries to use that much. It reserves
    nothing on the host up front.

The original (pre-REL-035b) version of this script summed both classes
together against one ceiling. That overstated real pressure: a live check on
`mini` (2026-07-07, `free -h`) showed 41/62 GB used, 21 GB available, while
the old model already flagged 85 GB "allocated" against a 50 GB ceiling. Most
of that 85 GB was LXC soft ceilings nobody was using
(`pct exec <id> -- cat /sys/fs/cgroup/memory.current` well under each CT's
configured limit) -- not real reservations.

This version splits the guard in two:

  1. Hard gate (fails CI/pre-commit): VM reservations + ZFS ARC + a fixed
     host reserve, against a 44 GB ceiling. This is the guard that actually
     protects against REL-016 (see below).
  2. Soft check (warns only, never fails): sum of LXC `dedicated` limits vs
     physical RAM. Visibility only -- CT limits are soft ceilings and don't
     pre-allocate anything, so they must never block a build.

Why this guard exists at all: `mini` is the only physical host this entire
homelab runs on (no failover, see CLAUDE.local.md). REL-016 froze the host
solid during ordinary load because RAM pressure pushed ZFS into a stall-wait
state on this host's single shared NVMe -- not CPU starvation, ZFS I/O stall
under memory pressure. The hard gate is a blast-radius guard against a repeat
of that exact freeze.

This does NOT gate on vCPU/thread count -- vCPU overcommit is fine on this
host (etcd/kubelet already win CPU scheduling contention via cpu.units,
REL-035). Only RAM headroom matters for the ZFS-stall failure mode this
guards against.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LXC_TF = REPO_ROOT / "terraform/stacks/proxmox/lxc.tf"
VM_TF = REPO_ROOT / "terraform/stacks/proxmox/vm.tf"

# --- Hard gate: VM reservations + ARC + host reserve, ceiling 44 GB --------
#
# Some VMs set `floating` (a lower balloon-driven floor Proxmox can deflate
# toward under detected host pressure) alongside `dedicated` (the ceiling).
# Live investigation on `mini` (2026-07-07, `qm status <id> --verbose`) found
# all 3 k3s VMs' *live* balloon target sitting at the FULL `dedicated`
# ceiling, not deflated to `floating` -- Proxmox only deflates once it has
# already detected host memory pressure, which wasn't present at measurement
# time. Since this guard exists to catch a *pending* pressure event before it
# happens, gating on the optimistic `floating` floor would understate
# exactly the risk it exists to catch -- a sudden allocation spike can't rely
# on a balloon that hasn't deflated yet. So the hard gate conservatively sums
# `dedicated` for every VM, not `floating`. `floating` is still parsed and
# printed for visibility, never counted.
ZFS_ARC_MAX_GB = 4  # confirmed live via /sys/module/zfs/parameters/zfs_arc_max
HOST_RESERVE_GB = 6  # kernel + hypervisor/qemu process overhead (non-ARC)
# REL-012d (2026-08-01): raised 44→46 GB. vm-srv-k3s-11 grew to 16 GB
# dedicated after the post-vacation cold-start crash loop (etcd read-index
# timeouts under CPU exhaustion on 4 cores). Host `mini` has 62 GB physical;
# 46 GB VM reservations + 4 GB ARC + 6 GB reserve leaves ~16 GB for LXC CT
# bursts, and live usage was 41/62 GB on 2026-07-07. Still ~16 GB under
# physical RAM; the REL-016 ZFS-stall blast-radius guard is preserved, just
# with the headroom the crash loop demonstrated was needed.
# REL-012d (2026-08-02): raised 46→50 GB. k3s-13 is ALSO a control-plane +
# etcd member (comment previously claimed "pure agent node" — wrong), sized
# at 4 cores / 8 GB while k3s-11 got 6/16 GB. It exhausted CPU/RAM under
# cold-start + steady load, stalling etcd and making k3s-11 lose Raft
# quorum → repeat crash loops (k3s-11 NRestarts 69, k3s-13 135). Both etcd
# members now 12 GB dedicated (36→40 GB VM sum) so the control plane has
# symmetric headroom. 50 GB total = 40 GB VMs + 4 GB ARC + 6 GB reserve,
# still 12 GB under physical RAM; live usage remains ~41/62 GB.
HARD_GATE_CEILING_GB = 50
HARD_GATE_CEILING_MB = HARD_GATE_CEILING_GB * 1024

# --- Soft check: LXC CT limits vs physical RAM, warn-only -----------------
PHYSICAL_RAM_GB = 62  # `free -h` total on mini, confirmed live (64 GB nameplate - firmware/DDR4 overhead)

DEDICATED_RE = re.compile(r"^\s*dedicated\s*=\s*(\d+)\s*$", re.MULTILINE)
FLOATING_RE = re.compile(r"^\s*floating\s*=\s*(\d+)\s*$", re.MULTILINE)


def sum_matches(pattern: re.Pattern, text: str) -> tuple[int, list[int]]:
    values = [int(m.group(1)) for m in pattern.finditer(text)]
    return sum(values), values


def main() -> int:
    if not LXC_TF.exists() or not VM_TF.exists():
        print(f"ERROR: expected {LXC_TF} and {VM_TF} to exist", file=sys.stderr)
        return 2

    vm_text = VM_TF.read_text()
    lxc_text = LXC_TF.read_text()

    vm_dedicated_total, vm_dedicated_values = sum_matches(DEDICATED_RE, vm_text)
    vm_floating_total, vm_floating_values = sum_matches(FLOATING_RE, vm_text)
    lxc_dedicated_total, lxc_dedicated_values = sum_matches(DEDICATED_RE, lxc_text)

    hard_gate_mb = vm_dedicated_total + (ZFS_ARC_MAX_GB * 1024) + (HOST_RESERVE_GB * 1024)
    hard_gate_gb = hard_gate_mb / 1024

    print("REL-035 memory overcommit guard (two-tier model)")
    print()
    print("-- Hard gate (CI-fail): VM reservations + ARC + host reserve --")
    print(f"  VM `dedicated` sum ({len(vm_dedicated_values)} VMs): {vm_dedicated_total} MB ({vm_dedicated_total / 1024:.1f} GB)")
    print(f"  VM `floating` sum  ({len(vm_floating_values)} VMs): {vm_floating_total} MB ({vm_floating_total / 1024:.1f} GB) -- informational only, NOT counted (see script header)")
    print(f"  + ZFS ARC max: {ZFS_ARC_MAX_GB} GB")
    print(f"  + host/hypervisor reserve: {HOST_RESERVE_GB} GB")
    print(f"  = hard gate total: {hard_gate_mb} MB ({hard_gate_gb:.1f} GB)")
    print(f"  Ceiling: {HARD_GATE_CEILING_GB} GB")

    print()
    print("-- Soft check (warn-only, never fails): LXC CT limits vs physical RAM --")
    print(f"  LXC `dedicated` sum ({len(lxc_dedicated_values)} CTs): {lxc_dedicated_total} MB ({lxc_dedicated_total / 1024:.1f} GB)")
    print(f"  Physical RAM: {PHYSICAL_RAM_GB} GB")

    exit_code = 0

    if hard_gate_mb > HARD_GATE_CEILING_MB:
        overage_gb = hard_gate_gb - HARD_GATE_CEILING_GB
        print(
            f"\nFAIL: hard gate total ({hard_gate_gb:.1f} GB) exceeds the "
            f"{HARD_GATE_CEILING_GB} GB ceiling by {overage_gb:.1f} GB.\n"
            f"\n"
            f"This ceiling exists specifically to prevent a repeat of REL-016: mini "
            f"froze solid under RAM pressure because ZFS stalled waiting on I/O on "
            f"this host's single shared NVMe, not because of CPU starvation. mini is "
            f"the sole physical host for this entire homelab (no failover) -- a "
            f"repeat of that freeze takes down every service at once.\n"
            f"\n"
            f"Trim a VM's `dedicated` value, or revisit the ceiling itself with "
            f"justification, before merging.",
            file=sys.stderr,
        )
        exit_code = 1
    else:
        print(f"\nOK: hard gate within ceiling ({hard_gate_gb:.1f} GB / {HARD_GATE_CEILING_GB} GB).")

    if lxc_dedicated_total > PHYSICAL_RAM_GB * 1024:
        overage_gb = (lxc_dedicated_total / 1024) - PHYSICAL_RAM_GB
        print(
            f"\nWARN: LXC CT `dedicated` limits sum to {lxc_dedicated_total / 1024:.1f} GB, "
            f"{overage_gb:.1f} GB over physical RAM ({PHYSICAL_RAM_GB} GB). This is "
            f"visibility only, not a failure -- CT limits are soft cgroup ceilings "
            f"(memory.max), not host reservations, and commonly sum past physical "
            f"RAM without real pressure. Check actual usage before treating this as "
            f"actionable: `pct exec <id> -- cat /sys/fs/cgroup/memory.current`.",
            file=sys.stderr,
        )
        # deliberately does not affect exit_code -- soft check never fails the build

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
