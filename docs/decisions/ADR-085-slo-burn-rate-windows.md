# ADR-085: SLO burn-rate alerts on the SRE Workbook windows

**Date:** 2026-11-25
**Status:** Accepted, applied

## Context

`kubernetes/system/monitoring/slo-rules.yml` defines a 99.9% availability SLO over 30
days for every blackbox probe (`probe_success`, 60s interval, 8 probes). Its two alerts
used home-made windows: a page at 30x on 2h and 1h, and a "ticket" at 6x on 6h and 30m.
Neither matches the SRE Workbook (chapter 5, "Alerting on SLOs"), the header comment
mis-stated the windows, and the description printed the 2h error ratio rather than a
burn rate, which made the number hard to compare with the threshold.

The Workbook's recommended set for a 30-day 99.9% SLO:

| Severity | Long window | Short window | Burn rate | Budget spent |
|---|---|---|---|---|
| Page | 1h | 5m | 14.4x | 2% |
| Page | 6h | 30m | 6x | 5% |
| Ticket | 3d | 6h | 1x | 10% |

The catch is traffic. At 60 probes an hour a single failed probe is a 1.7% error ratio
over 1h, already above the 14.4x threshold (1.44%). Replaying the last 30 days of
`probe_success` through each candidate rule (subqueries at 1m resolution) gave these
alert episodes across all probes:

| Rule | Episodes / 30d |
|---|---|
| Old page (30x, 2h/1h, for 2m) | ~10 |
| Workbook 14.4x 1h/5m, no `for` | ~46 |
| Workbook 14.4x 1h/5m, for 5m | ~17 |
| Workbook 14.4x 1h/5m for 10m, plus 6x 6h/30m for 1h (both pages combined) | ~9 |
| Workbook 1x 3d/6h ticket | ~13 |

Taken literally, the Workbook page rules would have quadrupled Discord pages, almost all
of them a single failed probe.

## Decision

Use the Workbook windows and burn rates unchanged, and handle the low probe volume with
`for:` instead of changing thresholds:

- `SLOAvailabilityFastBurn`: 14.4x on 1h and 5m, `for: 10m`, severity `critical`.
- `SLOAvailabilitySlowBurn`: 6x on 6h and 30m, `for: 1h`, severity `critical`.
- `SLOAvailabilityBudgetBurn`: 1x on 3d and 6h, `for: 1h`, severity `warning`.

The `for:` makes a page need failures that keep recurring inside the short window for
10 minutes (fast) or an hour (slow), which a lone failed probe cannot do. Page volume
on the replay stays at the old level (~9 vs ~10 episodes) while the windows and burn
rates become the standard ones. Detection of a hard outage takes about 11 minutes
instead of about 3; for a homelab that is acceptable.

Only the two page alerts are `critical`, so only they match the severity=critical
Discord route in `alertmanager-config.yml`. The ticket alert is `warning`, which no
route sends anywhere: it is visible in Alertmanager and Grafana only.

The alert expressions now compute the burn rate directly, so `$value` in the description
is the long-window burn rate as a multiple (for example `21.3x`), directly comparable with
the threshold. A `rate3d` recording rule was added and the unused `rate2h` dropped.

## Alternatives considered

- **Lower the SLO target (for example 99.5%).** Would cut noise without `for:`, but
  changes the promise rather than the alerting. Two probes (public analytics and media)
  are below 99.9% over the last 30 days; that is information the ticket alert should
  surface, not hide.
- **Probe more often.** 15s probes would give the 5m window enough samples, at four
  times the request load against public endpoints through Cloudflare. Not worth it for
  this.
- **Require a minimum count of failed probes.** Works, but it is a second threshold
  that drifts from the burn-rate math; `for:` keeps the rules readable.

## Consequences

- Discord page volume from SLO alerts stays about where it was.
- A slow, steady budget leak now shows up as `SLOAvailabilityBudgetBurn` in Alertmanager
  instead of going unnoticed.
- The Grafana SLO dashboard shows the 14.4x, 6x and 1x thresholds.
