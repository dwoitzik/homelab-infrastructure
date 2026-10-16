# Chaos Mesh

Resilience testing — validates that PodDisruptionBudgets, restart policies, and
app-level tolerance for transient failures actually work, rather than assuming
they do because they're declared.

## Schedules

None. The two weekly `Schedule` objects (`weekly-pod-kill`,
`weekly-network-latency`) selected opt-in labels — `chaos-kill: enabled`,
`chaos-network: enabled` — that no workload ever carried, so every run failed
with *no pod is selected*, left `weekly-pod-kill` stuck in a running
`PodChaos`, and `concurrencyPolicy: Forbid` then blocked all later runs. They
were also applied by hand with `kubectl apply`, outside ArgoCD.

Scheduled testing is covered by `dr-game-day`
(`kubernetes/system/monitoring/dr-game-day.yml`) instead: a quarterly, guarded
kill-and-time-recovery exercise against `homepage`. Ad-hoc experiments are
applied on demand.

## Dependencies

None. Ad-hoc runs target whichever apps are labelled for the experiment.
