# Architecture Decision Records

Every non-obvious infrastructure decision in this repo, in one place. See
`ADR-000-template.md` for the format. Numbers below aren't fully
sequential — 030 and 034 are reserved for decisions in review, not
skipped by accident.

| ADR | Decision | Status |
|---|---|---|
| [001](ADR-001-unbound-recursive-dns.md) | Unbound as recursive DNS resolver | Accepted |
| [002](ADR-002-keepalived-edge-ha.md) | Keepalived for edge node high availability | Accepted |
| [003](ADR-003-garage-terraform-backend.md) | Garage as self-hosted Terraform state backend | Accepted |
| [004](ADR-004-backup-strategy.md) | 3-2-1 backup strategy with PBS and rclone | Accepted |
| [005](ADR-005-nfs-over-longhorn.md) | NFS storage instead of Longhorn | Accepted |
| [006](ADR-006-cloudnativepg-authelia.md) | CloudNativePG for Authelia's Postgres backend | Accepted |
| [007](ADR-007-velero-kopia-pvc-backup.md) | Velero + Kopia for PVC-level backup | Accepted |
| [008](ADR-008-networkpolicy-default-deny.md) | Default-deny NetworkPolicies for apps and monitoring namespaces | Accepted |
| [009](ADR-009-vault-auto-unseal.md) | Vault auto-unseal via polling sidecar | Accepted |
| [010](ADR-010-media-acquisition-lxc.md) | Dedicated LXC for the media acquisition stack, VPN-wrapped at the network level | Accepted |
| [011](ADR-011-cloudflare-tunnel-external-access.md) | Cloudflare Tunnel for external service exposure (Immich) | Accepted |
| [012](ADR-012-atlantis-lxc-migration.md) | Move Atlantis out of k3s onto its own LXC | Accepted |
| [013](ADR-013-tor-proxy-indexer-queries.md) | Tor SOCKS5 proxy for indexer queries, fail-closed | Accepted |
| [014](ADR-014-etcd-topology.md) | etcd topology — restore single-server, or commit to real 3-node HA | Proposed |
| [015](ADR-015-k3s-datastore-sqlite.md) | k3s datastore — SQLite, not etcd | Accepted |
| [016](ADR-016-storage-class-policy.md) | Storage class policy — NFS-client default + local-path for embedded DBs | Accepted |
| [017](ADR-017-rpi-role.md) | Raspberry Pi role — DNS/edge only, not a k3s cluster member | Accepted |
| [018](ADR-018-kubernetes-distribution.md) | Kubernetes distribution — stay on k3s | Accepted |
| [019](ADR-019-k3s-vm-disk-placement.md) | k3s VM disk placement stays on NVMe thin-pool, not HDD | Accepted |
| [020](ADR-020-grafana-dashboard-curation-scope.md) | Grafana dashboard curation scope | Accepted |
| [021](ADR-021-atlantis-off-public-internet.md) | Replace Atlantis's public webhook with a self-hosted GitHub Actions runner | Accepted |
| [022](ADR-022-headscale-off-cluster-to-rpi.md) | Move Headscale off the k3s cluster to rpi-srv-02 | Accepted (decision only — see Consequences) |
| [023](ADR-023-shared-disk-bulk-io-guard.md) | Guard bulk background I/O jobs against the single shared NVMe | Accepted |
| [024](ADR-024-garage-meta-lmdb-dedicated-disk.md) | Garage metadata to LMDB on a dedicated disk, off local-path | Accepted |
| [025](ADR-025-vault-approle-for-recovery-agent.md) | Narrow Vault AppRole for the recovery agent, root token out of the working path | Accepted |
| [026](ADR-026-three-vm-topology-overhead.md) | Keep the 3-VM-on-one-host k3s topology | Accepted |
| [027](ADR-027-declared-vs-live-drift-guard.md) | Declared-vs-live drift guard for non-ArgoCD-managed manifests | Accepted |
| [028](ADR-028-mechanical-secret-exposure-prevention.md) | Make secret exposure mechanically impossible, not just against the rules | Accepted |
| [029](ADR-029-warm-standby-ha-headscale-vaultwarden.md) | Warm-standby HA for Headscale + Vaultwarden on rpi-srv-02 | Accepted, partially implemented |
| [031](ADR-031-jellyfin-stays-lxc-not-k8s.md) | Jellyfin stays on a dedicated LXC, not migrated into k3s | Accepted |
| [032](ADR-032-claude-agent-dedicated-tunnel.md) | claude.woitzik.dev gets its own Cloudflare Tunnel, not a firewall hole | Superseded 2026-08-27 |
| [033](ADR-033-public-exposure-allowlist.md) | Public exposure is an explicit allowlist of two hostnames, not a wildcard | Accepted |
| [035](ADR-035-scanopy-topology-mapping.md) | Scanopy for network topology mapping | Accepted |

## In review, not yet in this table

- **ADR-030** — Physical streaming-replication warm standby for Authelia's
  Postgres. Code-complete, unapplied, pending review of a new
  externally-reachable database endpoint before it's load-bearing.
- **ADR-034** — Proxmox host power and reliability tuning (CPU governor,
  ZFS tuning, backup throttling/health-check, watchdog backoff, RAPL
  metrics, swappiness).
