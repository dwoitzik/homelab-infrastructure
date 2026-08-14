# Chaos Mesh

Scheduled resilience testing — validates that PodDisruptionBudgets, restart policies,
and app-level tolerance for transient failures actually work, rather than assuming
they do because they're declared.

## Schedules

`schedules.yml`:
- **Weekly pod-kill** (Sunday 03:00 UTC) — kills one pod in `apps` namespace matching
  label `chaos-kill: enabled`. Opt-in per-app, not blanket — not every app is safe to
  chaos-test unattended.
- **Weekly network latency** (Sunday 03:30 UTC) — 100ms latency injected on ingress
  traffic to `apps` namespace for 5 minutes.

Both scheduled for low-traffic hours specifically so a real failure surfaces as a
Sunday-morning alert, not a user-facing incident.

## Dependencies

None. Targets whichever apps opt in via the `chaos-kill` label.
