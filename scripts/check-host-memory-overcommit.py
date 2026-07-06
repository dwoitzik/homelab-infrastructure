#!/usr/bin/env python3
"""REL-035 regression guard.

Sums every VM/CT's `dedicated` memory (MB) allocated on the single physical
host `mini` across terraform/stacks/proxmox/{lxc,vm}.tf and fails if the total
exceeds a hard ceiling.

Why this exists: `mini` is the only physical host this entire homelab runs on
(no failover, see CLAUDE.local.md). A prior incident (REL-016) froze the host
solid during ordinary load because RAM pressure pushed ZFS into a stall-wait
state on this host's single shared NVMe -- not CPU starvation, ZFS I/O stall
under memory pressure. This check is a blast-radius guard against a repeat of
that exact freeze: it fails loudly, in CI, before a Renovate/feature PR can
push total guest memory allocation past what the host + ZFS ARC can safely
absorb, rather than finding out the hard way during a live incident.

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

# --- Ceiling definition -----------------------------------------------------
# mini has 64 GB of physical RAM (62 GiB usable per `free -h` -- DDR4 overhead).
# Reserve breakdown for the ~14 GB withheld from the guest-allocation ceiling:
#   - ZFS ARC cap: 4 GB (zfs_arc_max, confirmed live via
#     /sys/module/zfs/parameters/zfs_arc_max -- already tuned down from the
#     8 GB default after REL-016/REL-012's disk-contention incidents)
#   - Proxmox host OS + hypervisor overhead: ~6 GB (kernel, qemu/lxc process
#     overhead per guest, ZFS metadata beyond ARC itself)
#   - Safety margin against a burst (e.g. a live migration, a snapshot,
#     unexpected host-side buffer growth): ~4 GB
# 64 - 4 - 6 - 4 = 50 GB left for guest `dedicated` memory allocation.
HOST_TOTAL_RAM_GB = 64
HOST_RESERVE_GB = 14  # ZFS ARC (4) + host/hypervisor overhead (6) + safety margin (4)
MAX_GUEST_MEMORY_GB = HOST_TOTAL_RAM_GB - HOST_RESERVE_GB  # 50 GB
MAX_GUEST_MEMORY_MB = MAX_GUEST_MEMORY_GB * 1024

DEDICATED_RE = re.compile(r"^\s*dedicated\s*=\s*(\d+)\s*$", re.MULTILINE)


def sum_dedicated_mb(path: Path) -> tuple[int, list[int]]:
    text = path.read_text()
    values = [int(m.group(1)) for m in DEDICATED_RE.finditer(text)]
    return sum(values), values


def main() -> int:
    if not LXC_TF.exists() or not VM_TF.exists():
        print(f"ERROR: expected {LXC_TF} and {VM_TF} to exist", file=sys.stderr)
        return 2

    lxc_total, lxc_values = sum_dedicated_mb(LXC_TF)
    vm_total, vm_values = sum_dedicated_mb(VM_TF)
    total_mb = lxc_total + vm_total
    total_gb = total_mb / 1024

    print(f"REL-035 memory overcommit guard: mini (single physical host, 64 GB RAM)")
    print(f"  LXCs ({len(lxc_values)} guests): {lxc_total} MB ({lxc_total / 1024:.1f} GB)")
    print(f"  VMs  ({len(vm_values)} guests): {vm_total} MB ({vm_total / 1024:.1f} GB)")
    print(f"  Total dedicated memory allocated: {total_mb} MB ({total_gb:.1f} GB)")
    print(f"  Ceiling: {MAX_GUEST_MEMORY_MB} MB ({MAX_GUEST_MEMORY_GB} GB) "
          f"= {HOST_TOTAL_RAM_GB} GB host RAM - {HOST_RESERVE_GB} GB reserved "
          f"(4 GB ZFS ARC + 6 GB host/hypervisor overhead + 4 GB safety margin)")

    if total_mb > MAX_GUEST_MEMORY_MB:
        overage_gb = total_gb - MAX_GUEST_MEMORY_GB
        print(
            f"\nFAIL: total guest memory allocation ({total_gb:.1f} GB) exceeds the "
            f"{MAX_GUEST_MEMORY_GB} GB ceiling by {overage_gb:.1f} GB.\n"
            f"\n"
            f"This ceiling exists specifically to prevent a repeat of REL-016: mini "
            f"froze solid under RAM pressure because ZFS stalled waiting on I/O on "
            f"this host's single shared NVMe, not because of CPU starvation. mini is "
            f"the sole physical host for this entire homelab (no failover) -- a "
            f"repeat of that freeze takes down every service at once.\n"
            f"\n"
            f"This is not a merge-blocking failure by default (see the workflow that "
            f"calls this script) -- it's a visible, explicit signal that total "
            f"allocation has grown past the safe ceiling and needs a deliberate "
            f"decision (trim a guest's `dedicated` value, or revisit the ceiling "
            f"itself with justification), not a silent creep.",
            file=sys.stderr,
        )
        return 1

    print("\nOK: within the memory-overcommit ceiling.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
