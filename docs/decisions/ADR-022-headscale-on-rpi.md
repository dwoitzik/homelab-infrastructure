# ADR-022: Headscale migrated off k3s onto rpi-srv-02

**Date:** 2026-08-17
**Status:** Accepted

## Context

`vm-srv-k3s-11` (the sole k3s control-plane, also running the cluster's SQLite/kine
datastore — see ADR-015) was flagged for `KubeAPIServerHighLatency` (p99 9.9s) and
carries 58 pods alongside the control plane itself, on a host with no CPU/memory
headroom to spare (see the same investigation's findings — the actual root cause
turned out to be Trivy Operator's SBOM report volume, not memory pressure, but the
underlying fact that this node runs the API server *and* dozens of unrelated
general-purpose workloads is still real and worth reducing regardless).

Both Raspberry Pis (`rpi-srv-01`/`rpi-srv-02`) run only DNS (unbound + AdGuard Home)
and lightweight monitoring sidecars — 8-11% RAM usage, essentially idle otherwise.
`rpi-srv-02` had a 111.8GB USB SSD (`/dev/sda`) physically attached and completely
unused, not even partitioned.

Headscale itself has no dependency on Kubernetes-specific features (no CRDs, no
ServiceAccount/RBAC use, no PVC dynamic provisioning beyond a plain data directory,
no ServiceMonitor scraping it in a way that requires in-cluster discovery) — it's a
single Go binary with a SQLite backend, a good match for the same native-Docker
pattern already used for unbound/AdGuard Home on both Pis.

## Decision

Move Headscale from a k3s Deployment (`kubernetes/apps/headscale/`) to a native Docker
Compose deployment on `rpi-srv-02`, storing its SQLite database on the newly-partitioned
SSD (`/mnt/ssd/headscale`, ext4, mounted via `/etc/fstab` with `nofail` — same caution
already applied to the other Pi's USB storage per `docs/compute-nodes.md`) rather than
the Pi's SD card (write-fragile, already documented as a hard constraint for this
hardware class).

Cutover done via the existing headless Service+Endpoints pattern
(`kubernetes/system/apps-ingressroute.yml`, matching `external-dns`/`external-pve`) —
`headscale-final`'s IngressRoute target repointed from the in-cluster `headscale`
Service to `external-headscale-rpi` (10.0.20.3:8080). No change to the Cloudflare
Tunnel or public DNS record (`headscale.woitzik.dev` stays public per ADR-019 — devices
re-authenticating need to reach it before any VPN path exists). Traefik's own TLS
termination and `websockets` middleware are unaffected; only the backend target moved.

Migrated the existing SQLite database and noise private key directly (not a fresh
install) — this is the real Headscale identity and existing device registrations
(the `dw` user, the `tailscale-subnet-router` node), not a new mesh.

## Reasons

- **Removes real, if modest, load from the one node the whole cluster's control plane
  depends on**, for zero functional loss — Headscale doesn't use anything k3s-specific.
- **Better hardware fit.** SQLite on a real SSD (vs. sharing `vm-srv-k3s-11`'s thin
  pool with etcd's kine layer and 57 other pods) removes one more workload from the
  storage contention that's already caused multiple real incidents this recovery
  (see `phase8/LEDGER.md` Entries 6-9).
- **Matches an already-proven pattern.** unbound and AdGuard Home already run this
  exact way (native Docker Compose on the Pis) — this isn't a new operational model,
  just applying an existing one to another lightweight, non-k8s-dependent service.
- **Cutover mechanism has near-zero blast radius and instant rollback.** Repointing a
  headless Service's Endpoints is a single manifest change with no DNS propagation
  delay and no Cloudflare Tunnel config involved — reverting to the k3s instance, if
  ever needed, is the same one-line change in the other direction.

## Trade-offs (accepted)

- Two different operational models now exist side by side for "small self-hosted
  services" (k8s Deployment vs. native Docker Compose) — a real, if minor, increase in
  operational surface area. Judged worth it given Headscale's genuine lack of
  Kubernetes-specific requirements and the direct benefit to the control-plane node.
- The Pi's own reliability characteristics (SD-card boot, single-board hardware, no
  redundancy) now apply to Headscale too, where they didn't before. Mitigated by the
  SSD (data, not boot media) and the Pi's own existing hardware watchdog / independent
  health-check tooling (`docs/compute-nodes.md` §2) already covering it.
- ArgoCD no longer manages Headscale's lifecycle — updates, restarts, and config
  changes go through direct Docker Compose operations on the Pi instead of GitOps.
  `docker-compose.yml`/config are still tracked in this repo for reference, but applying
  a change is now a manual `docker compose up -d` on the host, not an automatic sync.

## Consequences

- `kubernetes/apps/headscale/` (the k3s Deployment/Service/ConfigMap/PVC) is retained,
  not deleted, as the rollback path until the new instance has proven stable over a
  real period of use — decommissioning it is a deliberate follow-up, not done as part
  of this ADR.
- Follow-up: remove `kubernetes/apps/headscale/` from the ArgoCD `homelab-apps`
  ApplicationSet once the rpi-based instance is confirmed stable, and update this ADR's
  Status if anything about the migration needs revisiting.
