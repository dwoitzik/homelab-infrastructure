# ADR-062: Offsite R2 backup retains 3 days, not 7

## Status

Accepted and applied, 2026-10-18.

## Context

The Cloudflare R2 offsite leg of the 3-2-1 backup (`Schedule/daily-offsite`,
`kubernetes/system/velero/offsite-schedule.yml`) had been **paused for 14 days** and its
disaster-recovery copy was gone, not merely stale.

`r2-usage-guard` — the CronJob that enforces the free-tier budget, since R2 has no native
spending cap — pauses `daily-offsite` when stored bytes cross 9 GiB (a 1 GiB margin under
the 10 GiB free tier). It paused the schedule on/around 2026-10-04. Because the guard is
deliberately built with **no auto-resume** (a budget overrun is meant to be an operator
decision, not something that silently clears itself), the schedule stayed paused.

While paused, the schedule's own `ttl: 168h0m0s` kept doing its job: seven days after the
last run, every offsite Backup aged out and Velero pruned it from R2. The result was that
the mechanism meant to protect against a small billing overage ended up **deleting the
entire offsite backup set** — strictly worse than the ~$0.01/GB it was avoiding. At the
time this was found, R2 held only ~0.23 GiB of leftover kopia metadata and **zero** Backup
objects.

The bucket is small by design: `daily-offsite` covers only four namespaces (`apps`,
`vault`, `database`, `argocd`) and the large volumes (media, Prometheus/Loki/Garage data)
are opted out via `backup.velero.io/backup-volumes-excludes` pod annotations. A fresh full
offsite backup measured ~6.3 GB of raw volume data across 126 volumes, which kopia
deduplicates and compresses to roughly **4.0 GiB stored**. One full set therefore already
consumes ~45% of the 9 GiB guard; seven days of deduplicated daily deltas on top of that is
what drove usage to the cap in the first place, and would do so again.

## Decision

Drop the offsite `ttl` from `168h0m0s` to **`72h0m0s`** (3 days).

`daily-backup` (the local Garage leg) keeps its 7-day retention — it is not budget-bound.
The shorter window applies only to R2, where steady-state then sits near a single full set
plus two days of deltas (~5 GiB), comfortably under the 9 GiB pause threshold, so the guard
stops being a recurring near-miss.

## Consequences

- The offsite DR leg keeps ~3 days of restore points instead of 7. This is a real reduction
  in offsite history; it is accepted because a *deleted* offsite set (the previous outcome)
  provides zero restore points, and the local `daily-backup` still covers 7 days for
  near-term recovery.
- The pause/expiry failure mode is inherent to `r2-usage-guard`'s design: any future pause
  that outlives the TTL still wipes the offsite set. The guard's staleness notification
  (`offsite copy N h old`) fires within hours and is the intended catch — the schedule was
  left paused for two weeks because that notification went unactioned, not because it was
  missing. Lowering the TTL reduces how *often* the cap is approached but does not remove
  that dependency on the notification being read.
- Recovery from this specific incident: `daily-offsite` was unpaused and a fresh offsite
  backup ran to completion (0 errors, 2032 items, ~4.0 GiB stored) before this ADR was
  written.
