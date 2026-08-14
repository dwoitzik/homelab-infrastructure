# ADR-015: k3s datastore — SQLite, not etcd

**Date:** 2026-08-13
**Status:** Accepted

## Context

This cluster's documentation and prior handoff notes called its datastore "etcd"
throughout. During the 2026-08-13 disaster recovery, direct inspection of the
control-plane VM's disks found this was already false in practice: the live `etcd/`
directory was empty except a stub, and `state.db` — k3s's embedded SQLite datastore —
was the real, actively-written datastore. The documented architecture and the actual
running system had silently diverged at some point before this recovery began.

Separately, `docs/decisions/ADR-014-etcd-topology.md` already covers why this cluster
runs a single control-plane server rather than 3-way HA (a prior embedded-etcd HA attempt
caused repeated host freezes — all three k3s VMs share one physical host and one storage
pool, so 3 concurrent etcd writers produced enough I/O contention to lock the host up).
That ADR is about *topology* (how many servers). This one is about the *storage engine*
choice itself, which turned out to be a separate, compounding factor: `docs/HARDWARE.md`
documents the boot NVMe as DRAM-less, with no onboard cache to absorb write bursts —
etcd's fsync-heavy write pattern is a specifically bad fit for that hardware regardless of
how many servers are running it (see `REL-012c` in the repo's incident history, cited in
`docs/RECOVERY-REPORT-2026-08-13.md`).

## Decision

Keep the datastore as SQLite (k3s's default for single-server mode), rather than
reverting to etcd to match the old documentation. Formalize what had already silently
happened rather than fighting to restore an architecture that wasn't actually running.

## Reasons

- **It was already true.** The live system was already using SQLite, not etcd, before
  this recovery started. Reverting to etcd would have been a deliberate downgrade to a
  worse fit for the hardware, undertaken only to match documentation that was itself
  wrong.
- **SQLite's write pattern suits this hardware better.** A single-writer embedded
  database with less aggressive fsync behavior than etcd's Raft-log-per-write model is a
  meaningfully better match for a DRAM-less boot SSD (`docs/HARDWARE.md`'s central
  constraint, cited throughout this repo's architecture decisions).
- **Single-server topology (ADR-014) makes multi-writer etcd unnecessary anyway.** etcd's
  main advantage — surviving the loss of any one of several server nodes — doesn't apply
  when there's deliberately only one server node. Running etcd for a single-server
  cluster gets none of its benefit while keeping all of its extra write cost.
- **No data migration needed.** The cluster was rebuilt clean during this recovery
  (`docs/RECOVERY-REPORT-2026-08-13.md`'s inventory explicitly notes the old `state.db`
  was superseded by a fresh cluster, not migrated) — there was no in-place conversion
  requiring a risky live datastore swap either way.

## Trade-offs

- SQLite (via k3s's default single-server mode) has no built-in replication story. If
  `vm-srv-k3s-11` is lost, the control plane is lost with it — but this is already true
  under ADR-014's single-server topology regardless of which datastore backs it, so this
  ADR doesn't introduce new risk, it just names the datastore that topology decision
  already implied.
- Recovery from total control-plane loss depends entirely on backups of `state.db` (or,
  as practiced during this recovery, rebuilding the cluster fresh via GitOps + restoring
  workload data from Velero/PBS) rather than etcd's typical multi-member failover.

## Consequences

- `docs/HARDWARE.md`, `docs/k3s-architecture.md`, and `docs/RECOVERY-REPORT-2026-08-13.md`
  all now correctly describe the datastore as SQLite — this ADR is the canonical record
  of *why*, referenced from each of them rather than re-explained.
- Any future move back toward multi-server HA (revisiting ADR-014) would need to revisit
  this decision too, since multi-server k3s requires etcd (or an external datastore like
  MySQL/Postgres) — SQLite only supports single-server mode.
