# ADR-016: Storage Class Policy — Formalize NFS-client Default + local-path for Embedded DBs

**Date:** 2026-08-13
**Status:** Accepted
**Relationship to prior ADRs:** Extends ADR-005 (NFS over Longhorn). Does not supersede it —
ADR-005's reasoning for dropping Longhorn (multi-attach races on a volatile single-host VM
topology) still holds and is not revisited here. This ADR formalizes a decision that was
already made and implemented operationally (per `docs/k3s-architecture.md`) but never
written down as its own ADR: the follow-on migration of specific embedded-database apps
from `nfs-client` to `local-path`.

## Context

Phase 3 of the recovery brief asks explicitly whether Longhorn is a better fit than
"local-path + disciplined backup" for this cluster, given Longhorn's write cost on a
3-node cluster with poor disks. That question was already answered empirically before this
recovery even started, in two steps documented separately in this repo but never tied
together into one policy statement:

1. **Longhorn → NFS** (ADR-005, 2026-06): Longhorn's per-node volume-attach model didn't
   tolerate this cluster's volatility (VMs on a single host, occasional OOM/reboot) —
   RWO volumes ended up in `Multi-Attach error` loops. Migrated everything to a single
   `nfs-client` StorageClass backed by `ct-srv-nfs-01`.
2. **NFS → local-path, for embedded DBs only** (undocumented as an ADR, but real and
   already in production per `docs/k3s-architecture.md` §2): NFS's locking/WAL model is
   incompatible with SQLite/BoltDB-style embedded databases — this is not theoretical, it's
   how Garage's metadata store (`garage-meta`) actually corrupted in production. Every
   SQLite-backed app was subsequently moved to `local-path`: Garage metadata, Headscale,
   Vaultwarden, Gitea, Mealie, Open WebUI, Home Assistant, Uptime Kuma.

Both steps are consistent with current external guidance (confirmed 2026-08-13): k3s's own
storage docs describe `local-path` as node-local, appropriate where cross-node volume
portability isn't required, and treat NFS/distributed storage as the answer specifically
for cross-node shared-access needs — which is the inverse of what an embedded, single-writer
SQLite/BoltDB file needs (it wants low-latency local disk with correct file-locking
semantics, not network-shared storage with looser locking guarantees).

## Decision

Formalize the storage class policy already running in production as the deliberate,
documented design for the Phase 4 rebuild — not a migration to perform, but a decision to
carry forward and defend if questioned:

- **Default StorageClass: `nfs-client`.** Bulk/shared data, blob storage, anything without
  its own locking-sensitive embedded DB (media libraries, config that doesn't need
  low-latency local writes, anything that benefits from being schedulable to any node).
- **`local-path` for embedded-DB apps only**, by rule, not case-by-case judgment: any
  workload backed by SQLite, BoltDB, or an equivalent single-writer embedded store defaults
  to `local-path`. Current list: Garage metadata, Headscale, Vaultwarden, Gitea, Mealie,
  Open WebUI, Home Assistant, Uptime Kuma. New apps with an embedded DB join this list by
  default; moving one *off* `local-path` requires justification, not the reverse.
- **Exception, unchanged:** the Jellyfin `media` PVC is a direct NFS mount, not provisioned
  through the `nfs-client` provisioner, since it's large sequential bulk data with no
  locking concerns and no benefit from the provisioner's per-PVC lifecycle.
- **Longhorn stays out.** Not reconsidered — ADR-005's incident-driven reasoning
  (multi-attach races on this specific topology) is still valid and nothing about this
  recovery changes that.

## Reasons

- This is the option the brief itself half-suggests ("local-path + disciplined backup")
  and it is already the running design, validated by real incidents on both sides (Longhorn
  multi-attach, NFS+SQLite corruption) rather than a fresh guess.
- `local-path`'s node-pinning cost (data is gone if the node is lost, short of a Velero
  restore) is already the accepted trade-off — it's mitigated by Velero/kopia backups
  (ADR-007) covering exactly this namespace pattern, and by this recovery itself being the
  live proof that the backup path works end-to-end for these apps (Phase 1 of this recovery
  restored/verified every one of them from PBS + kopia).
- Keeps the policy legible: a new app's storage class is decided by one question ("does it
  have an embedded DB?"), not a fresh debate each time.

## Trade-offs

- `local-path` PVs cannot follow a pod to a different node. If `vm-srv-k3s-11` (the node
  every current `local-path` PVC is pinned to, since it's the sole server and stateful pods
  are scheduled there — see LEDGER Phase 1 findings) is lost, every one of these apps loses
  its live data until restored from backup. This is a real, accepted cost, not a hidden one
  — `DISASTER-RECOVERY.md` must document the exact restore procedure per app (Phase 4 task).
- `nfs-client`'s durability depends entirely on `ct-srv-nfs-01`'s own ZFS redundancy and
  Velero's daily backups — the NFS server is a SPOF for everything on that class, same as
  ADR-005 already accepted.
- This policy requires operator discipline going forward (new SQLite-backed apps must
  actually get `local-path`, not just default to whatever's convenient) — no admission
  webhook enforces it today. Worth a lightweight OPA/Kyverim policy or at minimum a
  pre-commit/CI check in a future iteration; not building it now since it's out of scope for
  the recovery itself.

## Consequences

- Phase 4 rebuild uses this policy as-is for every restored app — no new storage-class
  decisions to make per service, just apply the rule.
- `docs/k3s-architecture.md` §2 already describes this correctly in prose; this ADR is the
  formal record the doc was missing. No content change needed there, just a cross-reference
  to this ADR.
- Velero backup selection (ADR-007) should be double-checked during Phase 4 to confirm it
  actually covers 100% of the `local-path` namespace/PVC set — a gap here is a silent
  Tier-1 data-loss risk given the node-pinning trade-off above.

## How to reverse

Per-app: move an individual embedded-DB app back to `nfs-client` only if that specific
engine has been confirmed to tolerate NFS locking correctly (most don't) — document the
exception inline in that app's README per the repo's per-service documentation standard.
Wholesale reversal (back to Longhorn, or a new distributed storage layer) would need its own
ADR with fresh incident evidence, matching the bar ADR-005 itself was held to.

## Sources

- [Volumes and Storage | K3s](https://docs.k3s.io/add-ons/storage) — local-path vs NFS/distributed storage use cases
- [How to Configure K3s Storage Classes](https://oneuptime.com/blog/post/2026-01-27-k3s-storage-classes/view) — local-path vs Longhorn guidance
- Internal: `docs/decisions/ADR-005-nfs-over-longhorn.md`, `docs/k3s-architecture.md` §2, `/root/phase1/LEDGER.md` Entry 10 (this recovery's own confirmation of the local-path app inventory)
