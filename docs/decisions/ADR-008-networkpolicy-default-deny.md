# ADR-008: Default-deny NetworkPolicies for apps and monitoring namespaces

**Date:** 2026-06-19
**Status:** Accepted

## Context

Until 2026-06-19, every namespace in the cluster had unrestricted pod-to-pod ingress —
any pod could reach any other pod's exposed ports, across namespaces, with no policy
enforcement at all. This is a flat network inside the cluster regardless of trust level:
a compromised low-value workload (e.g. a media-stack container) would have had the same
network reach as Vaultwarden or Authelia.

Options considered:

- Leave the cluster network flat and rely on application-level auth only (Authelia,
  service-level secrets)
- Default-deny ingress per namespace, with explicit allow rules for required
  cross-namespace traffic
- A full service-mesh (e.g. Linkerd/Istio) policy layer — rejected as disproportionate
  operational overhead for this cluster's size

## Decision

Add default-deny-ingress `NetworkPolicy` resources to the `apps` and `monitoring`
namespaces (`kubernetes/apps/network-policies.yml`,
`kubernetes/system/monitoring/network-policies.yml`), with narrow explicit allows for
Traefik ingress, intra-namespace pod traffic, ArgoCD health checks, and monitoring scrape
traffic.

## Reasons

Default-deny is the only model that actually constrains a compromised pod's blast
radius — an allow-list of known-needed paths is auditable; a deny-list of known-bad paths
is not, because new cross-namespace dependencies get added constantly as the cluster
grows. Namespace-scoped Kubernetes `NetworkPolicy` objects require no extra controller
(Traefik's CNI — Flannel on k3s — already enforces them) and no additional operational
component, unlike a service mesh.

## Trade-offs

- **Rollout incident (2026-06-19):** the initial default-deny rollout silently broke two
  cross-namespace dependencies that weren't in the original allow-list: Velero couldn't
  reach Garage S3 (`apps` namespace) for backups, and Homepage's dashboard widget
  couldn't reach Uptime Kuma (`monitoring` namespace), throwing `ECONNREFUSED`. Neither
  produced an alert — Velero backups "completed" in a degraded state and Homepage just
  showed a broken widget. Both were discovered days later by symptom, not by any
  automated check, and fixed with scoped follow-up policies (`allow-from-velero`,
  `allow-from-apps` in monitoring)
- Every new cross-namespace integration now requires an explicit `NetworkPolicy` allow
  rule, or it fails silently in exactly the same way — there is no policy-violation
  alerting, only "the feature stopped working"
- Policies are namespace-scoped and manually maintained YAML; they will drift from actual
  traffic patterns over time without periodic review

## Consequences

Before adding any new service that talks across a namespace boundary (e.g. anything that
needs to reach Garage, Vault, or another namespace's pods), the relevant
`network-policies.yml` must be checked and a scoped allow rule added in the same PR —
this is documented in `ROADMAP.md` as a standing reminder. `kube-system` (Traefik, CoreDNS,
k3s control plane) and other namespaces remain unrestricted; default-deny has only been
rolled out to `apps` and `monitoring` so far, not cluster-wide.
