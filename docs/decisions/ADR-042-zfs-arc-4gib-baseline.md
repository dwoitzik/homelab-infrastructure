# ADR-042: ZFS ARC Max Lowered to 4 GiB as the New Baseline

**Date:** 2026-09-09
**Status:** Accepted.

## Context

A live incident today (host swap at 98.5% full, `vault-0`'s raft barrier
failing to persist, ~22 ArgoCD apps Degraded) was traced to real host
memory pressure. Unlike the first memory incident (ADR-037, 2026-08-29),
ZFS ARC wasn't the driver this time — it was already correctly capped at
8 GiB and only using 6.6 GB of that allowance. The actual cause: all 3 k3s
VMs' balloon `actual` had climbed to their full `dedicated` ceiling (32 GB
combined), not squeezed below it like the first incident. They're
genuinely *using* their full allocation now.

This reflects real workload growth on the cluster since the 8 GiB ARC
baseline was set 11 days earlier: Firefly's CNPG migration, rybbit
analytics, scanopy, and other services landed in the interim, each adding
real memory demand across the fleet, not just on `vm-srv-k3s-11` the way
ADR-036 addressed.

## Decision

Lowered `zfs_arc_max` from 8 GiB to 4 GiB, applied live first (freed ~2.2
GB of real host RAM within seconds, no reboot needed) then codified as the
git-declared baseline in `ansible/roles/pve_power`.

## Reasons

This is a baseline correction, not a temporary spike response. Reverting
to 8 GiB immediately after the incident would undo the exact margin that
just relieved it, on the strength of an assumption (8 GiB is enough
headroom) that today's incident directly disproved. The corrected
overcommit-guard math (`scripts/check-host-memory-overcommit.py`) with
4 GiB shows 42/58 GB — a genuine 16 GB margin, matching the guard's
original healthy-state reading before either incident.

## Trade-offs

Lower ARC hit rate for PBS/archive-pool (media, backup) reads with a 4 GiB
cap vs 8 GiB — accepted for the same reason ADR-037 accepted 16→8: that
pool serves large sequential reads that tolerate a smaller cache far
better than the cluster tolerates memory starvation.

## Consequences

- This is now the second cut to this constant in under two weeks (16→8→4).
  If a third incident traces back to ARC again, the real question stops
  being "how low should the cache go" and becomes whether the cluster's
  workload has outgrown this host's 62 GB of physical RAM entirely —
  spreading load further (in the style of ADR-036) or adding physical RAM
  are the real levers at that point, not another ARC cut.
- Revisit this value if workload growth continues at the same pace, or if
  PBS/media read performance measurably degrades (check `arc_summary`'s
  hit ratio before assuming the cache is the cause).
