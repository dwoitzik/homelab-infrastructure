# ADR-024: Garage Metadata to LMDB on a Dedicated Disk, Off local-path

**Date:** 2026-08-21
**Status:** Accepted

## Context

Garage's metadata store (`garage-meta`) was a 2Gi PVC on the `local-path`
StorageClass, using the `sqlite` `db_engine`. Two separate, real incidents this
session motivated revisiting both choices:

1. A SQLite metadata corruption (root-caused as downstream fallout from an
   earlier `.recover` repair operation) crash-looped Garage for 14+ hours
   (`phase8/LEDGER.md` Entries 54-56), ultimately requiring a full wipe and
   re-provision (Entry 71) rather than an in-place repair.
2. `local-path`'s PVC for `garage-meta` had no explicit node pinning anywhere
   in the Deployment — it lived wherever the pod happened to first schedule,
   sharing that node's generic, undifferentiated local-lvm-backed storage
   directory with every other `local-path` consumer on that node, with no
   isolated capacity accounting or discard behavior of its own. (Confirmed
   live: `docs/garage-velero-design-2026-07-17.md` recorded it on
   `vm-srv-k3s-13` on 2026-07-17; by this session it had moved to
   `vm-srv-k3s-11` — the *control-plane* node — with nothing in git driving
   that placement either way.)

`ADR-019` already settled that k3s VM (and by extension, this host's other
critical) storage belongs on the NVMe thin-pool, not the HDD-backed `archive`
pool — latency, not wear, is the binding constraint for anything on this
node's critical path, and that reasoning applies here too: Garage's metadata
store is on the hot path for every S3 request this cluster's backups and
Terraform state depend on.

## Decision

Two changes, done together as one migration:

1. **`db_engine`: `sqlite` → `lmdb`.** LMDB has been Garage's own documented
   default since v0.9.0 (sqlite was this cluster's historical choice, not a
   deliberate pick against LMDB). Migrated via Garage's own documented
   `garage convert-db` command — a real conversion of live metadata (4
   buckets, 4 keys, existing objects), not a fresh empty reinit. Added
   `metadata_auto_snapshot_interval = "6h"`, Garage's documented mitigation
   for LMDB's own stated risk ("prone to database corruption after an
   unclean shutdown") — the other documented mitigation, `replication_factor
   >= 2`, isn't available on this single-node hardware.
2. **Storage: `local-path` PVC → dedicated hostPath.** A new 8G virtio-scsi
   disk (`discard=on`), attached directly to `vm-srv-k3s-11`, formatted ext4
   (`noatime`, `discard`), mounted at `/mnt/garage-meta-dedicated`. The
   Deployment now carries an explicit `nodeSelector: kubernetes.io/hostname:
   vm-srv-k3s-11` (previously only incidental via `local-path`'s own PV
   affinity) and mounts that path via `hostPath` instead of a PVC.

This is **not** a relocation off the NVMe thin-pool — per ADR-019's own
reasoning (still valid, re-affirmed here rather than silently overridden),
this hardware has exactly one fast disk, and Garage's metadata store is
squarely the kind of low-latency, corruption-sensitive workload ADR-019
already decided belongs there. What changed is *isolation*: a dedicated
volume instead of sharing `local-path`'s common directory tree with
everything else on whichever node the pod lands on.

## Options considered for "off local-path"

**Move to `nfs-client` (the only other StorageClass this cluster runs).**
Rejected. `docs/garage-velero-design-2026-07-17.md` already analyzed this
exact move for the SQLite engine and concluded "NFS locking is not harmless"
— the 2026-07-12 corruption on NFS-backed storage was real, direct evidence.
LMDB's storage model (memory-mapped file access) is at least as exposed to
network-filesystem locking/coherency hazards as SQLite's own WAL, likely more
— nothing about switching engines changes this rejection, if anything it
strengthens it.

**Move to the USB-attached `archive` HDD.** Rejected outright by
`CLAUDE.local.md`'s own hard rule: "Never place stateful PVs or databases on
USB-attached storage or SD cards." `garage-data` (the actual object blobs)
already lives there deliberately (`ADR-` implicit in `garage.yml`'s own
`REL-019` comment — large sequential writes, slow-is-fine); metadata is the
opposite access pattern and explicitly excluded by that same rule.

**A genuinely separate physical disk.** Not available — this host has one
NVMe and one USB HDD (`docs/HARDWARE.md`), no third option, and the operator's
own standing constraint for this recovery pass rules out a hardware purchase.
Revisit if that changes.

**Do it via Terraform (`terraform/stacks/proxmox`) instead of a manual `qm
set`.** Preferred in principle, blocked in practice: Atlantis's own Garage
API key credentials were invalidated by the same-session Garage wipe (Entry
71) and haven't been re-propagated yet (blocked on this agent having no
configured Vault access) — Atlantis cannot plan/apply *anything* right now
regardless of stack. Applied live instead, matching the same "apply now,
codify in IaC once the credential gap closes" pattern already used this
session for `/etc/lvm/lvm.conf`, `/etc/vzdump.conf`, and `pve-watchdog.sh`.
The new disk attach (`vm-211-disk-1`) is not yet reflected in
`terraform/stacks/proxmox/vm.tf` — a known, tracked gap, not a silent one.

## Consequences

- Garage's metadata store now has its own capacity ceiling (8G) independent
  of whatever else runs on `vm-srv-k3s-11`, and its own discard behavior —
  no longer subject to `local-path`'s shared-directory fate.
- The `garage` Deployment is now hard-pinned to `vm-srv-k3s-11`. If that VM is
  ever rebuilt or replaced, the new disk attach and hostPath must be
  recreated first, or the pod will fail to schedule (`hostPath` with `type:
  Directory` fails closed if the path doesn't exist, rather than silently
  falling back).
- The old `garage-meta` `local-path` PVC (2Gi) is left in place, unused, as a
  cheap rollback point until this new setup has run stable for longer — not
  urgent to reclaim now that item 1's thin-pool threshold fix
  (`ansible/roles/pve_power`) restored real headroom.
- `terraform/stacks/proxmox/vm.tf` needs a follow-up PR adding `vm-211-disk-1`
  once Atlantis's credentials are restored, so this isn't permanently
  drifted, live-only state.

## How to reverse

Revert `kubernetes/apps/garage/garage.yml`/`config.yml` to their prior
`persistentVolumeClaim`/`sqlite` state, `garage convert-db -a lmdb -i
/mnt/garage-meta-dedicated/db.lmdb -b sqlite -o <new-path>/db.sqlite`, and
detach `vm-211-disk-1` via `qm set 211 --delete scsi1` (only after confirming
no data loss — this is a destructive step, do it deliberately). The old
`local-path` PVC's data is stale as of the migration timestamp, not a live
fallback — don't treat it as one without re-running `convert-db` against it
first.
