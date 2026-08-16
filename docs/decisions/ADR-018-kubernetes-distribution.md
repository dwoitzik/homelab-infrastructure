# ADR-018: Kubernetes Distribution — Stay on k3s

**Date:** 2026-08-13
**Status:** Accepted

## Context

Phase 3 of the recovery brief requires testing, not assuming, that k3s is still the right
choice, and specifically asks whether k0s, Talos, or plain kubeadm are "meaningfully
different... on this dimension [write amplification], or just different packaging of the
same etcd problem."

This is evaluated after ADR-015 (drop etcd, move to embedded SQLite) — the actual root
cause of this hardware's write-amplification problem was etcd's fsync-heavy raft log, not
k3s as a distribution. Any distro choice has to be judged against that already-corrected
baseline, not against the old etcd-based pain point.

## Decision

Stay on k3s. Do not switch to k0s, Talos, or kubeadm.

## Reasons

**k0s (researched 2026-08-13):** k0s's single-controller mode uses the same underlying
mechanism as k3s's SQLite mode — a `kine` shim translating the etcd API to a SQL backend
(SQLite by default for single-node). This directly confirms the brief's own hypothesis for
this specific pair: once single-node SQLite/kine is the actual choice (ADR-015), k0s and
k3s are not meaningfully different on the write-amplification dimension — they're the same
mechanism with different packaging, exactly as the brief suspected. Since they're
equivalent on the one dimension actually in question, and this repo already has k3s-specific
tooling (Ansible roles, Terraform-adjacent docs, prior ADRs written in k3s terms), switching
would cost real migration effort for zero measurable benefit.

**kubeadm:** Vanilla kubeadm doesn't bundle a lightweight single-node datastore story the
way k3s/k0s do — it still expects etcd for anything beyond the most manual, hand-held
single-node setups, and comes with none of k3s's batteries-included integrations
(Traefik, ServiceLB/local-storage, the containerd bundling) already relied on throughout
this repo. Adopting it would mean re-solving problems k3s already solves, for a distribution
explicitly aimed at a different operating model (large clusters, dedicated platform teams) —
the wrong tool for a single-operator homelab.

**Talos Linux:** The most genuinely interesting alternative, and the one given the most
consideration. Talos is an immutable, API-only OS purpose-built for Kubernetes — no SSH, no
shell, no package manager, entire system managed declaratively. Its appeal for this
specific failure history is real: it structurally prevents the kind of undocumented manual
drift that caused ADR-014's whole incident (a node quietly becoming an etcd server outside
of any tracked process). But two things weigh against adopting it now:

- It solves *configuration drift*, not the *write-amplification* problem this Phase 3
  section is actually about — that problem is already addressed at its root by ADR-015.
  Talos would be solving a different, real, but separate problem.
- The migration cost is high and falls specifically on the parts of this recovery that are
    already stable: the entire Ansible-based host/VM management layer (`ansible/site.yml`,
    `k3s-cluster/`, vault-backed secrets applied via Ansible) assumes a normal Linux guest
    with SSH access. Talos would require rebuilding that whole operational model
    (`talosctl`/machine-config in place of Ansible) for the k3s VM guests specifically,
    while every other host/LXC in this repo stays on the current model — a split
    operational story, adding complexity right when this recovery's goal is reducing it.

Configuration drift (Talos's strength) is a real, separate risk this repo should keep
watching for — but it's better addressed by process (this recovery's own emphasis on
everything-as-code, GitOps, and ADRs like this one closing exactly this kind of gap) than by
a full OS swap undertaken at the same time as several other major changes (ADR-015's
datastore migration, the host-level LVM-thin migration already completed this session).
Stacking a Talos migration on top of those would violate this recovery's own anti-loop /
one-change-at-a-time discipline (brief §9) for a benefit that's real but secondary to the
Phase 3 mandate.

## Trade-offs

- Forgoes Talos's structural drift-prevention. Mitigated by process discipline (GitOps
  selfHeal already reverts in-cluster drift; ADR-014's drift was host-VM-level, outside
  Kubernetes itself — Talos wouldn't have prevented *that specific* drift anyway, since it
  was about which VM ran the k3s server role, not in-cluster resource drift).
- k3s remains a Rancher/SUSE-maintained downstream of upstream Kubernetes rather than
  Talos's from-scratch OS design — accepted, matches this repo's existing risk posture
  (already depends on k3s specifics throughout).

## Consequences

- No distro migration work scheduled for Phase 4 — proceed directly to rebuilding on k3s
  with the ADR-015 SQLite datastore change.
- Revisit Talos specifically if a future incident is traced to host/VM-level configuration
  drift again (the ADR-014 failure mode) despite this ADR's process mitigations — that would
  be new evidence process alone isn't sufficient, changing the cost/benefit calculation here.

## How to reverse

Full cluster rebuild on the chosen alternative distro, following the same Phase 4 rebuild
order already used for k3s (control plane → GitOps → secrets → auth → backups →
observability → Terraform → workloads) — this is a from-scratch redeployment, not an
in-place conversion, for any of the three alternatives considered.

## Sources

- [Storage Backend (etcd/Kine) | k0sproject/k0s](https://deepwiki.com/k0sproject/k0s/4.2-containerd)
- [Storage Configuration | k0sproject/k0s](https://deepwiki.com/k0sproject/k0s/6.3-storage-configuration)
- [k3s-io/kine | DeepWiki](https://deepwiki.com/k3s-io/kine) — kine as the shared etcd-API-to-SQL shim underlying both k3s's and k0s's single-node SQLite modes
- [Talos Linux: No SSH, No Shell — Production Guide (2026)](https://alexandre-vazquez.com/talos-linux-guide/)
- [Self-Hosted Kubernetes: k3s vs k0s vs Talos Linux — Best Lightweight K8s Distros 2026 | Pi Stack](https://www.pistack.xyz/posts/k3s-vs-k0s-vs-talos-linux-self-hosted-kubernetes-guide-2026/)
