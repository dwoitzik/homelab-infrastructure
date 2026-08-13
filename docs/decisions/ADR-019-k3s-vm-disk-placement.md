# ADR-019: k3s VM Disk Placement Stays on NVMe Thin-Pool, Not HDD

**Date:** 2026-08-13
**Status:** Accepted

## Context

Phase 3 of the recovery brief lists as one of the hypotheses to test: "Would relocating
the datastore's write path help — different filesystem, different mount options, or
physically elsewhere?" This needs an explicit answer, not just an implicit one left over
from ADR-015's datastore change.

During this recovery's Phase 1, the three k3s VMs were restored to scratch VMIDs
(911/912/913) on `media` (the HDD-backed `archive` ZFS pool) rather than the NVMe
thin-pool — but that placement was a deliberate Phase 1 safety choice (inspect-only,
never-boot, keep write pressure off the wear-sensitive NVMe during a read-only forensic
pass), not a proposal for where the real, rebuilt VMs should live in Phase 4.

`CLAUDE.local.md`'s hard storage rules are direct on this point already: *"The only
reliable disk is the 512 GB SSD... All critical persistent state (Longhorn replicas,
Immich Postgres, Vaultwarden DB) lives there"* and *"The 2 TB USB HDD is for backup
(Garage) and Jellyfin media... slow is fine."* This ADR exists to confirm that rule still
holds now that the underlying problem (etcd's write pattern, ADR-015) has changed, rather
than assuming it without checking.

## Decision

k3s VM disks (all three: server + 2 workers) are placed on the host's NVMe LVM-thin pool
(`pve/data`), the same pool every other production VM/LXC on this host already uses —
**not** the HDD-backed `archive` pool. Guest-level filesystem/mount tuning mirrors the
host fix already applied in Phase 2: ext4, `noatime`, and a capped-persistent journald
policy inside each VM, applied via the same Ansible role used for the host where
practical.

## Reasons

- **Latency, not just wear, is the real constraint for a k8s API datastore.** Even with
  etcd removed (ADR-015), the k3s server still does real synchronous writes on every API
  mutation (SQLite's own WAL fsync). An HDD's random-write/seek latency is categorically
  worse than NVMe's for this access pattern — moving the VM disk to HDD to save NVMe wear
  would trade a wear problem (already substantially reduced by ADR-015) for a latency
  problem (API responsiveness, scheduling latency, every `kubectl` interaction). That's a
  worse trade, not a neutral one.
- **The actual fix for NVMe wear was removing etcd, not relocating the file.** ADR-015's
  research (etcd's fsync-forced writes, ~20x realistic write-amplification factor) shows
  the write volume itself is what mattered, and that's addressed at the source. Relocating
  a now-much-lighter SQLite write path to slower storage doesn't meaningfully protect the
  NVMe further and actively costs performance — diminishing returns on a problem that's
  already been solved a different way.
- **Consistency with the rest of the host.** Every other VM/LXC already lives on the
  NVMe thin-pool (confirmed live: `lvs pve` lists `vm-100`/`200`/`201`/`202`/`203`/`204`/
  `220`/`301`/`302`-disk-0 all in the `data` thin pool). Putting only the k3s VMs on HDD
  would be a one-off exception with no remaining justification post-ADR-015, adding
  operational surprise for no benefit.

## Trade-offs

- NVMe wear from the k3s VMs' guest-level writes (SQLite WAL, container image layers,
  kubelet/containerd logs, journald) is real and ongoing, just smaller than the etcd-era
  baseline. Mitigated by the same Phase 2 write-reduction toolkit applied at the host level
  (noatime, capped journald) applied again inside each guest, plus the Phase 4/5
  monitoring check on datastore growth already committed to in ADR-015.
- This decision assumes ADR-015 actually lands as designed (SQLite, not etcd) — if a
  future trigger condition forces a reversion to etcd (per ADR-015's own reversal
  procedure), this ADR's cost/benefit calculation should be re-checked at the same time,
  since etcd's heavier write pattern was the whole reason this question was worth asking.

## Consequences

- Phase 4 rebuild: provision `vm-srv-k3s-11/-12/-13` disks on the `pve/data` thin pool
  (via `terraform/stacks/proxmox/vm.tf`, same pattern as the other VMs), not `media`.
- Extend the host's write-reduction Ansible tasks (journald cap, noatime) to the k3s VM
  guests as part of the standard node provisioning, rather than a one-off manual step.
- Baseline SMART write-volume measurement from Phase 2 (`docs/`/LEDGER: 45% wear, 26.9TB
  lifetime `Data Units Written` at time of this recovery) remains the reference point for
  judging whether ADR-015 + this ADR's combined effect actually reduces the write rate
  going forward, per the brief's "measure before and after" requirement.

## How to reverse

Migrate the specific VM disk(s) to `media` storage via `qm move-disk` (or equivalent
Terraform change) if NVMe wear resumes climbing at an etcd-era rate despite ADR-015 — that
would indicate this decision's premise (SQLite writes are meaningfully lighter) was wrong
in practice, not just in research, and is worth re-measuring before reversing rather than
assuming.
