# Homelab Roadmap

Last full review: 2026-11-05 (security, stability, performance/storage wear, network).
The previous roadmap, written around the August rebuild, is kept unchanged in
[`docs/archive/ROADMAP-2026-08.md`](archive/ROADMAP-2026-08.md).

This file lists goals and work packages. Detailed findings with evidence for open
security items are tracked outside the public repository and land here once fixed.

## Operating principles

Every item below is done so it stays done without someone remembering it:

- **Updates are automatic.** Renovate covers container images, GitHub Actions,
  Terraform providers, pre-commit hooks and, since November 2026, the Helm charts
  referenced from ArgoCD Applications. Patch releases auto-merge after a three-day soak
  once every CI check passes, including a job that renders each chart with this repo's
  values against the cluster's Kubernetes version. Minor and major releases arrive as PRs.
- **Drift is detected, not discovered.** GitOps for the cluster (nothing hand-applied),
  Terraform through the PR-comment workflow, Ansible with a scheduled drift report.
- **Every failure mode that bit once gets an alert.** A fix is not finished until the
  same failure would page.
- **Changes are verified against live state**, not against a green pipeline or a
  "Synced" label.

## Done in this review

| Area | Change |
|---|---|
| TLS | Wildcard renewal unblocked (cert-manager v1.14 → v1.19.6, DNS-01 egress); renewal-overdue alert; weekly report reads origin certificate expiry |
| Secrets | External Secrets Operator reconnected to Vault after a hand-applied NetworkPolicy cut it off; sync-failure alert; ESO metrics scraped for the first time |
| Policy | Kyverno policies moved under GitOps, extended to init containers and the `security` namespace; drift CronJob for running pods |
| CI | Terraform plan/apply workflows restricted to the repository owner and to same-repo branches |
| Backups | Immich photo library mirrored nightly to the archive pool with 30 days of ZFS snapshots and a staleness alert |
| Services | OnlyOffice removed (unused); Enshrouded server checks Steam for new builds every 15 minutes |
| Alerting | Drive-wear warnings reach Discord; RESOLVED notifications delivered (group interval no longer outlives Alertmanager's resolved-alert GC); failed and missing PBS backup runs page |

## Now (November 2026)

### Storage wear: replace the host NVMe before it reaches 90 %

The Proxmox boot/VM drive is at 80 % rated wear and writes about 135 GB/day. At that
rate it reaches 90 % around the end of December.

- [ ] Order a replacement: ≥1 TB, DRAM, TLC, ideally with power-loss protection
      (fsync-heavy workload: kine, Postgres, LMDB). Swap in a December window.
- [ ] Cut write volume (estimates in GB/day saved):
  - [x] vzdump falls back to suspend mode for one container and staged ~19 GB on the
        host root every other night: staging moved to an ACL-capable dataset on the
        archive pool (~9)
  - [x] Datastore churn: provisioner lease removed, Kyverno lease retry 2s → 10s,
        ArgoCD reconcile 5 → 15 min, Velero BSL validation hourly (~8–10). The CNPG
        operator lease stays at 2s: no retry flag, and disabling leader election would
        let two operators overlap during a rolling update
  - [x] CNPG `archive_timeout` 5 → 30 min (~5–8). Found on the way: the postgres
        Application ignored every Cluster spec, so no Cluster change had ever deployed;
        it now uses server-side diff/apply
  - [ ] Garage metadata snapshots every 6 h; Loki chunk sizing (~3–5)
  - [ ] Prometheus: drop duplicate kubelet-scraped apiserver series (~2–3)
  - [x] Remove Chaos Mesh (no experiments; daily re-rollout from a random chart annotation)
  - [ ] VM filesystems `noatime,commit=60` + periodic fstrim; weekly `pct fstrim`
- [ ] Correct `docs/HARDWARE.md`: `nfs-client` volumes live on the NVMe, not the HDD.

### Backups that would actually restore

- [ ] Immich library offsite copy (R2)
- [x] Base backups for every CNPG cluster (Authelia's schedule also ran hourly instead of daily: CNPG cron has a seconds field)
- [ ] Consistent database backups: `pg_dump` pre-hooks instead of file copies of live data directories
- [ ] PBS: daily schedule, weekly verify job, offsite sync of the datastore
- [ ] kine datastore `.backup` to separate storage
- [ ] Monthly restore test extended from Vault to a Postgres database

### Security hygiene

- [ ] Retire the remaining Atlantis deployment (replaced by GitHub Actions, ADR-021) and rotate its tokens. Ingress and config removed; server teardown on the runner host and token revocation pending
- [x] Remove unused cluster tooling with broad permissions (Chaos Mesh, Keel)
- [ ] Hypervisor patch management and account hardening under Ansible
- [ ] One ingress path for all public services so every request passes the same rate limiting and CrowdSec bouncer
- [ ] Commit the remaining hand-applied NetworkPolicies; default-deny ingress for every namespace
- [ ] Pod Security `baseline` enforced in application namespaces
- [ ] Secrets encryption at rest in the cluster datastore; unseal material handled separately from data backups
- [ ] Merged-but-unapplied Terraform changes (network, Cloudflare) planned and applied

### Headscale / remote access

- [ ] Upgrade 0.29.2 → 0.29.7 (Android peer-list crash, OIDC re-login, exit-node route fixes)
- [ ] Exit nodes advertise IPv6 without an IPv6 uplink: stop advertising `::/0` until VLAN 20 has real IPv6
- [ ] Subnet router sits behind hard NAT and relays everything through DERP: host networking + a UDP port forward, or move the role to the Raspberry Pi
- [ ] Apply the pending DNS change for the control-plane hostname (ADR-059)
- [ ] Clean up stale nodes and unapproved route advertisements
- [ ] Make the documented standby (ADR-029) real, or remove it from the docs

### DNS

- [ ] Unbound: enable DNSSEC validation (trust anchor), keep local zones insecure
- [ ] Keepalived: health-check AdGuard/Unbound so the DNS VIP fails over when the resolver dies
- [ ] Lower `cache-min-ttl`

## Next (December 2026 – January 2027)

### Platform upgrades, one step at a time

- [ ] k3s 1.31 → 1.37, one minor per step with a snapshot before each, automated via
      system-upgrade-controller plans that Renovate bumps
- [ ] External Secrets 0.10 → current (`v1beta1` → `v1` manifests)
- [ ] Vault 1.17 → 2.2 (raft snapshot first)
- [ ] Traefik latest 2.11 → v3
- [ ] ArgoCD, CloudNativePG, Kyverno, Velero, MetalLB, kube-prometheus-stack to current
- [ ] Promtail and Tempo charts are deprecated: move log shipping to Grafana Alloy
- [ ] Jellyfin 10.11 → 12.x, Immich and Headscale kept current by Renovate

### Reliability

- [ ] Real Postgres standby for Authelia on the Raspberry Pi (ADR-030 is not implemented yet)
- [ ] Alertmanager `Watchdog` drives the dead man's switch instead of a CronJob
- [ ] Stale failed Jobs cleaned up automatically so `KubeJobFailed` means something
- [ ] Nextcloud and Firefly III background jobs: re-enable or decommission the apps
- [ ] Resource requests on every pod; cluster able to lose a node without memory overcommit
- [ ] Scheduled Ansible drift report and apply loop; fix non-idempotent tasks and the AdGuard role
- [ ] cloudflared: two replicas, metrics and an alert on tunnel connections
- [ ] MetalLB pool and DHCP ranges separated from static addresses

### Raspberry Pi SSD

- [ ] Boot rpi-srv-02 from its SSD instead of the SD card
- [ ] Use it as a second, physically separate backup target for small critical state
      (Vault, Vaultwarden, Headscale, kine, database dumps)
- [ ] Evaluate running Prometheus there to take ~8 GB/day off the host NVMe and keep
      alerting alive during a host outage

### Network

- [ ] QoS: replace the simple queue (bypassed by FastTrack) with a CAKE queue tree on the WAN interface
- [ ] Router input chain limited to the management ports each source actually needs
- [ ] Brute-force detection on the router rewritten as an address-list ladder
- [ ] Remove stale VPN and proxy firewall rules

## Later

- [ ] Publication hygiene: host-level addressing, provider IDs and investigation diaries
      move to a private overlay; the public repo keeps architecture, code and decisions
- [ ] README rewritten as an architecture and skills overview
- [ ] Observability gaps: Traefik, Garage and promtail metrics; probes for Jellyfin and Nextcloud
- [ ] SLO burn-rate rules aligned with the SRE workbook windows; annotations corrected
- [ ] IPv6 beyond ULA once the provider delegates a prefix
