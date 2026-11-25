# Homelab Roadmap

Last full review: 2026-11-05; status updated 2026-11-25 (security, stability, performance/storage wear, network).
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
  - [x] Garage metadata snapshots every 6 h; Loki chunk sizing (~3–5)
  - [x] Prometheus: drop duplicate kubelet-scraped apiserver series (~2–3)
  - [x] Remove Chaos Mesh (no experiments; daily re-rollout from a random chart annotation)
  - [x] VM filesystems `noatime,commit=60` + periodic fstrim; weekly `pct fstrim`
- [x] Correct `docs/HARDWARE.md`: `nfs-client` volumes live on the NVMe, not the HDD.

### Backups that would actually restore

- [ ] Immich library offsite copy (R2, ~74 GiB, about $1/month): owner decision
- [x] Base backups for every CNPG cluster (Authelia's schedule also ran hourly instead of daily: CNPG cron has a seconds field)
- [x] Consistent database backups: `pg_dump` pre-hooks instead of file copies of live data directories
- [x] Vault backed up as a consistent raft snapshot instead of a raw copy of its data directory
- [x] PBS: daily schedule and weekly verify job; GC failures, verify failures and stale
      verify runs page (GC had been failing since 2026-11-22 on a cache inside the datastore)
- [ ] PBS offsite sync of the datastore (~238 GiB, about $3.40/month on R2): owner decision
- [x] kine datastore copied off-host every 6 h (`VACUUM INTO`, integrity-checked, rpi-srv-02 SSD), restore tested
- [x] Monthly restore test extended from Vault to a Postgres database (CNPG recovery into a scratch cluster); Vault half fixed to check the raft snapshot

### Security hygiene

- [ ] Finish retiring the Atlantis deployment that GitHub Actions replaced (ADR-021),
      including its credentials. Server, config, dead GitHub token and webhook secret
      removed (ADR-021 "Retirement"); left: list HashiCorp Vault KV paths and remove any
      Atlantis-only entry
- [x] Remove unused cluster tooling with broad permissions
- [x] Hypervisor patch management and account hardening under Ansible
- [x] One ingress path for every public service, so all requests pass the same rate
      limiting and CrowdSec bouncer
- [x] Every NetworkPolicy under GitOps; default-deny ingress in every namespace
- [x] Pod Security `baseline` enforced in application namespaces (`apps`,
      `changedetection`); host-level agents live in `host-agents`
- [x] Encryption at rest for cluster secrets; key material kept apart from data backups
      (ADR-077)
- [x] Merged Terraform changes planned and applied promptly

### Headscale / remote access

- [x] Keep Headscale current
- [ ] Exit-node route advertisements match what each node can actually serve (ADR-043).
      Blocked on an IPv6 uplink: no host here has IPv6 egress, and Tailscale has no
      IPv4-only exit node. Needs FritzBox prefix delegation to the MikroTik first.
- [x] Direct peer connections for the subnet router instead of relayed traffic. Host side
      done (ADR-076: endpoint-independent NAT, fixed port 41641); still to prove with an
      off-LAN client, plus a UDP 41641 forward (FritzBox and MikroTik) for carriers with
      a hard NAT
- [x] Control-plane DNS served by Cloudflare (ADR-059)
- [x] Make the documented standby (ADR-029) real, or remove it from the docs: docs now
      describe an off-host replica, not a standby (ADR-029, 2026-11-12 status)
- [ ] Finish the headscale/vaultwarden standby: identity keys and OIDC secret on
      `rpi-srv-02`, standby config kept in sync with the primary, one rehearsed failover

### DNS

- [x] DNSSEC validation in Unbound
- [x] Health-checked keepalived failover for the DNS VIP

## Next (December 2026 – January 2027)

### Platform upgrades, one step at a time

- [x] k3s to a supported minor (1.31 to 1.34), one minor per step with a snapshot before
      each; the binary-swap procedure is in `docs/runbooks/k3s-upgrade.md` (ADR-080)
- [x] Platform components to current releases: Vault 2.2.2, ArgoCD 3.6.3, CloudNativePG
      1.30.2 with PostgreSQL 17.12, Kyverno 1.19, MetalLB 0.16.2, kube-prometheus-stack 93
- [ ] Remaining platform majors, each needing its own migration: External Secrets (v1beta1
      to v1), Traefik v2 to v3, Velero one minor at a time to 1.18, Kyverno 1.20 (policies
      to ValidatingPolicy)
- [x] Move log shipping from the deprecated Promtail chart to Grafana Alloy
- [x] Application majors (Jellyfin, Immich, Headscale) kept current by Renovate (Renovate
      auto-merge was stalled since 2026-11-15 by a wrong git author; Immich server and ML
      kept in lockstep by CI). Jellyfin 12 waits for an SSO plugin build

### Reliability

- [x] Real Postgres standby for Authelia on the Raspberry Pi (ADR-030, streaming since 2026-11-23)
- [x] Alertmanager `Watchdog` drives the dead man's switch instead of a CronJob
- [x] Stale failed Jobs cleaned up automatically so `KubeJobFailed` means something
- [x] Nextcloud and Firefly III background jobs: re-enable or decommission the apps
- [x] Resource requests on every pod (k3s-bundled local-path-provisioner excepted); requests
      fit after losing a worker, checked by `KubeMemoryOvercommitWorkerLoss`
- [x] Scheduled Ansible drift report: weekly check-mode run from the Proxmox host, ntfy only
      on drift (ADR-084). Applying stays manual.
- [x] cloudflared: two replicas, metrics and an alert on tunnel connections
- [x] MetalLB pool and DHCP ranges separated from static addresses

### Raspberry Pi SSD

- [ ] Boot rpi-srv-02 from its SSD instead of the SD card
- [ ] Use it as a second, physically separate backup target for small critical state
      (Vault, Vaultwarden, Headscale, kine, database dumps)
- [ ] Evaluate running Prometheus there to take ~8 GB/day off the host NVMe and keep
      alerting alive during a host outage

### Network

- [x] QoS with a CAKE queue tree on the WAN interface
- [ ] Router input chain scoped per source to the ports each one needs (IN-05 API ports
      still open to the whole SRV VLAN with no known consumer)
- [x] Router brute-force protection reworked (ADR-086): MAC WinBox/Telnet limited to
      admin interfaces, connection-flood list for WAN 443
- [x] Remove stale firewall rules (7 rules with zero hits removed)

### Corrections found by the blog audit (2026-11-25)

A technical audit of every woitzik.dev post checked its claims against this repo.
These are the places where the repo itself is wrong or internally inconsistent; the
posts already say the correct thing.

- [x] `kubernetes/apps/garage/garage.yml` sets `GARAGE_CONFIG`, which Garage ignores
      (it reads `GARAGE_CONFIG_FILE`). It only works because `/etc/garage.toml` is the
      default path. Rename the variable or drop it.
- [x] ADR-046: port 8200 is `0x2008`, not `0x2014`; the `/proc/net/tcp` check looked
      for port 8212 and proves nothing. A timeout instead of a refusal means the
      listener still existed but was not serving, so the "nothing was listening"
      reasoning needs rewriting.
- [x] Alert on LXC memory-cgroup pressure (`memory.events` `high` rate or
      `memory.pressure`). The tmpfs stall in ADR-066 showed up only as host load;
      ~8 million `memory.high` events had accumulated before anything paged.
- [x] ADR-066: tmpfs pages cannot stay resident "well past" the 4 GB limit; the excess
      was reclaimed and swapped. Reword.
- [x] ADR-069: "24 deleted files" (SteamCMD log) and "the executable and 32 `.dat`
      containers were missing" contradict each other. Settle the count.
- [x] ADR-045: the access log shows `wiso+steuer`, the direct test `wiso steuerung`,
      both described as "the same queries".
- [x] ADR-040: `auth.woitzik.dev` has no public A record; inside the LAN and the
      cluster it resolves to the Traefik VIP through the AdGuard rewrite. Fix the wording.
- [x] `ansible/roles/monitoring_agent/templates/promtail.yml.j2` labels `container`
      from `attrs.name`, but `daemon.json` sets no `labels`/`env`/`tag` log-opts, so
      `attrs` is empty and the label is never set. Use Docker service discovery
      (`__meta_docker_container_name`) or retire the template if Alloy has replaced it.

## Later

- [x] Publication hygiene: provider IDs, WAN details, audit lists and investigation
      diaries moved out of the public repo; it keeps architecture, code and decisions
- [x] README rewritten as an architecture and skills overview
- [ ] Deployable hostnames via a private kustomize overlay (ADR-048 follow-up)
- [x] Observability gaps: Traefik, Garage and log-shipper metrics; probes for Jellyfin and Nextcloud
- [x] SLO burn-rate rules aligned with the SRE workbook windows; annotations corrected
- [ ] IPv6 beyond ULA once the provider delegates a prefix
