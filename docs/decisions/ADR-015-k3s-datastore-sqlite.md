# ADR-015: k3s Datastore — Drop etcd, Move to Embedded SQLite

**Date:** 2026-08-13
**Status:** Accepted
**Supersedes:** The etcd-retention half of ADR-014 (ADR-014's single-vs-multi-member
analysis remains historically accurate and is not wrong — this decision goes one step
further than ADR-014 considered and removes etcd from the stack entirely, rather than
just fixing its topology).

## Context

This cluster runs on a single physical host (`mini`) with a DRAM-less NVMe boot SSD — a
combination that has already caused two classes of real incidents documented elsewhere in
this repo: the `docs/compute-nodes.md` ZFS ARC-pressure freezes, and ADR-014's account of
a 2-member etcd cluster losing quorum under host load on 2026-07-09, plus a second
etcd-adjacent outage on the same date when a plain `kubectl drain` (not even etcd member
removal) spiked load to 29+ and degraded the API server cluster-wide.

ADR-014 addressed *etcd topology* (how many members) and correctly concluded single-member
is better than the 2-member drift that had crept in. But it left the deeper question
unexamined: **does this cluster need etcd at all?**

The cluster has never run, and has no near-term plan to run, more than one k3s server.
`mini` is a documented, accepted single point of failure (`docs/k3s-architecture.md`:
*"Target is fast recovery, not zero-downtime HA: mini is a single point of failure either
way"*; `CLAUDE.local.md`: *"Zero-downtime HA is NOT achievable with this hardware — do not
pretend otherwise"*). etcd's entire value proposition — Raft consensus across multiple
members for HA — is being paid for in full (constant fsync-heavy writes) while delivering
zero benefit, since there has only ever been one member that actually matters.

### What etcd actually costs on this hardware

Research (2026-08-13) confirms the mechanism, not just the symptom already observed
locally:

- etcd forces a full fsync on every write and is extremely sensitive to fsync latency —
  slow disk means slow consensus, which cascades into API server instability. It cares
  about small-write fsync latency, not sequential throughput, which is exactly the profile
  a DRAM-less SSD is worst at (no write cache to absorb bursts of small sync writes).
- A homelab-scale etcd workload (~50 KB/s logical writes) can produce roughly 80 GB/day of
  *actual* physical writes once NAND write amplification (block-erase-on-page-write) is
  accounted for — a 20x amplification factor is a realistic real-world figure, not a worst
  case.
- k3s's own documentation confirms SQLite is the default and intended datastore for
  single-server deployments, specifically because it avoids this write/fsync profile;
  embedded etcd is recommended only when actual multi-server HA is wanted.

### The counter-risk: does SQLite have its own failure mode?

Yes, and it's worth naming honestly rather than assuming SQLite is a free win. A
documented real-world case (a homelab k3s cluster running dozens of leader-electing
operators — ArgoCD, Crossplane, CloudNativePG, EMQX, Longhorn, multiple observability
stacks, six operators each renewing a lease every ~2s) hit a kine/SQLite compaction
death-spiral: ~55,000 dead revisions per lease accumulated into 1.36M rows, a 13.8 GB WAL
that stopped checkpointing, and CPU pinned at 99% until they migrated to etcd (which has
working native MVCC compaction) and the datastore shrank from 7.5 GB back to 313 MB.

This repo's actual workload does not resemble that case. This cluster runs a "handful of
apps" workload (per `docs/k3s-architecture.md`'s app inventory — Vaultwarden, Gitea,
Headscale, Garage, Vault, Mealie, Open WebUI, Home Assistant, Uptime Kuma, plus the usual
system components), not dozens of leader-electing operators. The failure mode above
requires sustained high-frequency lease churn from many concurrent operators — a "platform"
workload, in the source's own words, not a "homelab" one. This cluster is deliberately kept
at homelab scale (see ADR-014's rejection of Option B partly on blast-radius grounds); if
that scale assumption changes materially (e.g. adding several more leader-electing
operators), this ADR's conclusion should be revisited.

## Decision

Migrate the k3s server (`vm-srv-k3s-11`, the sole server) from embedded etcd to the
embedded SQLite datastore. No other node ever becomes a k3s server — this is consistent
with, not a change to, the already-accepted no-HA posture.

Mechanically, on rebuild (Phase 4): install k3s server *without* `--cluster-init` and
without any `--datastore-endpoint` — SQLite is used automatically whenever no etcd files
are present on disk and no clustering flags are passed. `-12`/`-13` remain agent-only,
unchanged from today.

## Reasons

- Removes the exact write pattern (small, frequent, fsync-forced) that has already caused
  two real incidents on this hardware, for a consensus guarantee this cluster structurally
  cannot use (one server, one host, accepted SPOF).
- This cluster's actual scale (a handful of apps, no leader-election-heavy operator fleet)
  is well below the threshold where SQLite/kine's known compaction weakness has been shown
  to bite in practice.
- Reversible without redesign: k3s supports converting an existing SQLite-backed server to
  etcd later by restarting with `--cluster-init` — if this cluster ever needs to graduate to
  a "platform" workload profile (matching the failure case researched above), the path back
  to etcd is a documented, single-command operation, not a re-architecture.
- Directly answers the Phase 3 brief's core question ("what control plane survives on a
  DRAM-less SSD") with the lowest-write-amplification option that still satisfies every
  hard constraint (Kubernetes stays, GitOps stays, survives unclean power loss — SQLite's
  WAL mode is crash-safe on unclean shutdown, same guarantee etcd's WAL gives).

## Trade-offs

- SQLite cannot be used with more than one k3s server — this decision forecloses any future
  path to real multi-server HA without first migrating back to etcd. Given ADR-014 and
  `CLAUDE.local.md` both already treat multi-server HA as off the table for this hardware,
  this is accepting a constraint that was already de facto true, not creating a new one.
- If this cluster's workload profile grows into the "platform" territory described in the
  Reasons section (many leader-electing operators), SQLite/kine's compaction weakness is a
  real, documented risk, not a hypothetical one. Mitigation: watch datastore file size and
  API server latency as part of the standard monitoring stack (Phase 4/5) and treat sustained
  growth as an early warning, not something to discover via an outage.
- SQLite backup/restore is file-copy-based (snapshot the file), simpler than etcd's snapshot
  tooling but requires the k3s server to be stopped (or the copy taken via a
  filesystem-consistent snapshot, e.g. LVM) for a guaranteed-consistent backup — document
  this explicitly in `docs/RECOVERY.md`.

## Consequences

- `ansible/k3s-cluster/inventory.yml`'s etcd heartbeat/election-timeout tuning
  (100ms→500ms, 1000ms→5000ms, referenced in ADR-014) becomes dead configuration and should
  be removed during Phase 4 rebuild rather than carried forward unused.
- PBS/VM-level backup of `vm-srv-k3s-11` remains the primary datastore backup path (as it
  already effectively was); no separate etcd-snapshot cronjob needs to be built.
- Monitoring (Phase 4/5): add a Prometheus check on the SQLite datastore file size and
  k3s apiserver request latency, specifically so the failure mode identified above is caught
  as a trend, not an outage.
- `docs/k3s-architecture.md` and `docs/compute-nodes.md` need updating to reflect
  SQLite-backed, not etcd-backed, control plane — tracked as a Phase 4 documentation task.

## How to reverse

Restart the k3s server process with `--cluster-init` (converts the existing SQLite state to
an initial etcd cluster in place, per k3s's documented migration path) — no data loss, no
VM rebuild required. Should only be triggered by the specific, measured trigger condition in
Trade-offs (sustained datastore growth / compaction pressure observed in monitoring), not
preemptively.

## Sources

- [Cluster Datastore | K3s](https://docs.k3s.io/datastore) — SQLite default behavior, single-server limitation
- [High Availability Embedded etcd | K3s](https://docs.k3s.io/datastore/ha-embedded)
- [Embedded SQLite migration to ETCD Cluster · k3s-io/k3s Discussion #9432](https://github.com/k3s-io/k3s/discussions/9432) — SQLite→etcd migration via `--cluster-init`
- [When Your Homelab Grows Up: How SQLite Took Down My k3s Control Plane](https://wostal.eu/blog/homelab-grows-up-sqlite-to-etcd/) — kine compaction death-spiral case study, scale/trigger analysis
- [K3s read/writes and wear on flash storage · k3s-io/k3s Discussion #7694](https://github.com/k3s-io/k3s/discussions/7694) — etcd fsync sensitivity, write amplification figures
- [The SSD That Cried Etcd](https://bsid.io/writing/the-ssd-that-cried-etcd) — etcd fsync-vs-throughput characteristics
