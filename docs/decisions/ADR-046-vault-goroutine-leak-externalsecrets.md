# ADR-046: Vault goroutine leak wedged the server and silently broke all 32 ExternalSecrets

**Status:** Accepted and applied, 2026-09-30

## Context

On 2026-09-30, chasing an unrelated alert led to a much larger finding: every one
of the cluster's 32 `ExternalSecret` objects had been reporting
`Ready: SecretSyncedError - could not get secret data from provider`, and
`vault-0` had been `0/1` (not Ready) for roughly 20 days.

The 20-day figure comes from Prometheus (`kube_pod_status_ready` for `vault/vault-0`),
not from log inspection. Nothing alerted on it: the two conditions that would have
caught it — `KubeStatefulSetReplicasMismatch` and `KubePodNotReady` — were firing
continuously in the same window, but their noise level had trained them out of being
read as incidents.

## What was actually wrong

Two independent faults stacked on top of each other.

**1. Vault was wedged, not merely sealed.** The process was alive (5h50m of CPU)
and the PVC was `Bound`, but nothing was listening on 8200 — no `0x2014` entry in
`/proc/net/tcp` — and every `wget`/`vault status` against it timed out rather than
being refused. A `SIGQUIT` goroutine dump explained it: over 160,000 goroutines,
every one of them parked in `[select, 29459 minutes]`, i.e. for 20.5 days, spawned
from `serviceregistration/kubernetes/client.(*Client).do`. The service-registration
client had accumulated a goroutine per failed retry and never released any of them.

**2. `service_registration.kubernetes` had no RBAC.** The standalone config in
`application.yml` enables it with an empty block, so Vault tries to read its own pod
object. The only binding the chart creates for the `vault` ServiceAccount is
`system:auth-delegator` (tokenreviews, subjectaccessreviews), which does not include
pods. Every attempt therefore returned 403, retried every 5 seconds, forever.

Fault 2 is what made fault 1 unbounded: each 403 spawned another goroutine, and
nothing ever closed them.

## Decision

Apply both halves of the fix rather than only the visible symptom.

- **Restart the wedged pod.** Snapshot of VM 211 taken first
  (`vault-hang-pre-snapshot`). A pod delete is all that was needed — no data
  touched, the raft store is on the `data-vault-0` PVC.
- **Add the missing RBAC** (`kubernetes/system/vault/rbac.yml`, PR #804). A namespaced
  Role and RoleBinding for the `vault` ServiceAccount covering pods, endpoints,
  services and `pods/exec`, added to the `vault-manifests` ApplicationSet include
  list. Namespaced rather than ClusterRole on purpose: the only object this feature
  needs is vault's own pod, so the grant stays inside one namespace.

## Verification

Against the running system, not the pod status:

- `sealed: false` within 10s of restart — the existing `vault-unseal` sidecar
  (ADR-009) did its job unaided, which is the check that matters here.
- All 32 `ExternalSecret` objects returned to `Ready=True`.
- The 403 line stopped appearing in `vault-0`'s logs.

## Consequences

- Apps did not visibly break during the 20 days because Kubernetes Secrets are
  materialized at pod start and the affected pods had not restarted in a way that
  needed a re-sync. That was luck, not design: any pod restart, any node drain, or
  any credential rotation during that window would have failed.
- There is still no alert on `ExternalSecret` sync failure. That is the gap that let
  20 days pass, and it is the more important half of this ADR. The `KubeJobFailed`
  and `TargetDown` alerts that were firing constantly made the genuinely new signal
  easy to miss.

## Follow-up not done here

- An alert on `kube_external_secret_status_condition{condition="Ready"} != 1`.
- A goroutine-count or memory-growth guard on `vault-0`; the leak was visible in
  resource metrics long before it became fatal.
- A question worth answering separately: why 160,000 goroutines did not trip the
  1Gi memory limit set in `application.yml`. The container was sitting at 1022Mi,
  right at the ceiling, which is consistent with the leak but means the limit was
  the only thing still containing it.
