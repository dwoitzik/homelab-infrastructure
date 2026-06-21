# Changelog

All notable changes to this infrastructure are documented here.

## [Unreleased]

## [0.6.0] — 2026-06-21

### Added
- k3s HA: all 3 nodes (`vm-srv-k3s-11/12/13`) run as control-plane + embedded etcd,
  live-migrated from single-node SQLite (`--cluster-init`) — no rebuild required
- k3s API HA VIP (`10.0.20.10`) via Keepalived, health-checked against `systemctl is-active k3s`
- Vault auto-unseal sidecar (`vault-unseal` Deployment) — no more manual unseal after every Vault restart
- Independent DNS health alerting on both RPis — Discord webhook, zero dependency on the
  k3s/Prometheus stack, so it still works on days the cluster itself is down
- Hardware watchdog (BCM overlay + systemd `RuntimeWatchdogSec`) on both RPis — self-heals
  from a total system freeze, not just a crashed container
- Host firewall (`nftables`, additive `inet hostfw` table) on both RPis for natively-bound
  services; deliberately does not touch Docker's own iptables-nft managed tables
- fail2ban (sshd jail) on both RPis
- Per-container `mem_limit` on every RPi Docker workload
- Local rotating config backup (systemd timer, 14-snapshot retention) for RPi DNS configs —
  these are physical hosts, not LXCs/VMs, so PBS/Velero never covered them
- Docker daemon-wide log size cap (`max-size: 10m`, `max-file: 3`) — unbounded json-file
  logs were a real long-term disk-fill risk on SD-card-backed hosts
- Gitleaks secret scanning: pre-commit (staged), pre-push (full history), and CI — three
  independent layers against committing new secrets
- MikroTik service hardening: telnet/ftp disabled, api/api-ssl scoped to `10.0.0.0/8`
  (`terraform/stacks/network/imports.tf`, adopted via native `import` blocks)
- Cloudflare R2 offsite Velero backup location (configured, pending API credentials)
- Cobblemon Minecraft server (Fabric, `mc-server-cobblemon`) on `ct-dmz-games-01`, routed
  through `ct-dmz-proxy-01` (NPM stream + CrowdSec), same pattern as the existing server
- `cloudflare-ddns` CronJob — keeps `cobblemon.woitzik.dev` in sync with the actual WAN IP
- `docs/secrets-inventory.md`, `docs/OPERATIONS.md` — central "where is X / why does Y
  happen" reference docs

### Fixed
- **Critical**: `daily-backup` Velero schedule was missing `defaultVolumesToFsBackup` —
  backups completed "successfully" while only capturing k8s manifests, not actual PVC data
  (Postgres, Vaultwarden, Paperless, Nextcloud). Found and fixed 2026-06-19, verified with
  a Kopia pod-volume-backup test restore.
- NetworkPolicy default-deny rollout (2026-06-19) had silently broken two cross-namespace
  paths (Velero→Garage, Homepage→Uptime Kuma) for days before being noticed
- AdGuard PTR query flood: `private_networks` was unscoped, forwarding reverse-DNS lookups
  for the k3s pod network (`10.42.0.0/16`) to the Fritzbox, which can't answer them — each
  query burned a 2s timeout, looking like a DNS outage at cluster scale
- AdGuard's Ansible template had drifted badly from the live config (schema_version 28 vs
  live 34) — rebuilt from the running config, recovering 3 DNS rewrites that only ever
  existed via the web UI and would have been lost on a from-scratch RPi rebuild
- Traefik ArgoCD sync had been silently broken for over a day (`tlsStore` Helm schema
  mismatch) — every manual fix attempt during that window never actually reached the cluster
- ArgoCD repo-server Helm/manifest cache staleness caused `kubectl apply` changes to
  silently revert within seconds, hit on tempo, traefik, and paperless-gpt the same day
- paperless-gpt title generation defaulted to English regardless of document language —
  `LANGUAGE=deu` (ISO code) was injected verbatim into the LLM prompt; switched to the
  plain word "German" and added an explicit strict-language instruction
- Proxmox host repeated hard freezes: boot-time resource storm (all VMs/LXCs starting
  simultaneously, load avg 147 within 4 min) fixed via staggered `startup` order; a second,
  load-independent freeze traced to depleted/dried-out thermal paste (not a software issue)
- CI was silently unreliable: local `ansible-lint` (6.17.2, apt-installed) was 20 major
  versions behind what CI installed unpinned (26.4.0) — pinned both to match, plus a
  pre-push hook that runs the exact same checks before any push leaves the machine

### Removed
- `processor.max_cstate=1 idle=nomwait` kernel parameter (briefly applied as a suspected
  fix for the Proxmox freezes, reverted after it pushed idle CPU temps to 96°C — the actual
  cause was thermal paste, not C-states)
- **36 orphaned MikroTik firewall rules** (live router had 77, only 22 matched
  `firewall_deterministic.tf`). Several rounds of past "reconstruct deterministic firewall"
  work had each added a fresh copy of the ruleset without removing the previous one —
  3-4 full generations were stacked in the live `forward` chain. Since RouterOS evaluates
  rules in order and stops at the first match, the *oldest* (broadest) generation was
  actually winning over the newest, narrowest one: e.g. an unscoped `"04a: SRV - Allow
  monitoring to all internal VLANs"` fired before the intended `"port 9100 only"` version
  ever got evaluated — silently undoing that tightening. Removed via direct REST API calls
  (read-only diff against the 22 current `.tf` resources first, full per-rule restore
  script staged as a one-shot RouterOS scheduler "dead man's switch" before any delete,
  cancelled only after DNS/SSH/WAN were verified still working). 41 rules remain: the 22
  Terraform-managed ones plus 19 distinct rules with real, non-duplicate functions (VPN,
  Atlantis/MikroDash API access, WireGuard, Cobblemon, monitoring scrape, OIDC) that were
  never added to Terraform in the first place — those are tracked as a follow-up to bring
  under IaC.

## [0.5.0] — 2026-06

### Added
- k3s cluster (3 nodes on Proxmox VMs) — control-plane + 2 workers
- ArgoCD GitOps — ApplicationSet auto-deploys `kubernetes/apps/*`
- Traefik ingress with wildcard TLS (`*.woitzik.dev` via cert-manager DNS-01)
- Longhorn distributed block storage (3× replication across k3s nodes)
- MetalLB LoadBalancer (IP 10.0.20.200)
- Authelia SSO/OIDC — protects all internal services; integrated with Proxmox, PBS, Grafana, ArgoCD
- Headscale (self-hosted Tailscale control plane)
- Velero backups → Garage S3 (`velero` bucket, daily at 03:00)
- Garage S3-compatible object storage — replaces Minio; buckets: velero, terraform-state
- Terraform state migrated from local to Garage S3 backend
- kube-prometheus-stack (Prometheus + Grafana + Alertmanager) in `monitoring` namespace
- Loki log aggregation + Promtail DaemonSet
- prometheus-pve-exporter for Proxmox host metrics
- node_exporter on all external hosts (RPi: Docker; AI/PBS: native binary)
- Grafana dashboards: Node Exporter Full (1860), Proxmox PVE (10347, 19022)
- Atlantis self-hosted GitOps runner (migrated to k3s from Docker LXC)
- Cloudflare Tunnel (migrated to k3s)
- Authelia + PostgreSQL + Redis (migrated to k3s, `database` namespace)
- Vaultwarden (migrated to k3s)
- Paperless-ngx (migrated to k3s)
- Open WebUI / Ollama local LLM interface (migrated to k3s)
- Uptime Kuma service monitoring
- Homepage dashboard with kubernetes/ArgoCD/Grafana widgets
- Renovate Bot CronJob (dependency updates via GitHub PRs)
- Mealie recipe manager
- Nextcloud (files, CalDAV, CardDAV) + PostgreSQL + Redis
- Gitea private git instance
- Home Assistant smart home hub
- `node_exporter_native` Ansible role — installs node_exporter as systemd service (for non-Docker hosts)
- AdGuardHome.yaml.j2 Ansible template with DNSSEC, HaGeZi/OISD blocklists
- Wildcard certificate (`wildcard-woitzik-dev-tls`) in `kube-system`

### Changed
- DNS/edge layer simplified: RPis now handle only AdGuard + Unbound + Keepalived
- Reverse proxy migrated from Nginx Proxy Manager to Traefik in k3s
- Monitoring migrated from standalone Prometheus/Grafana to kube-prometheus-stack
- Terraform state backend changed from local to Garage S3
- k3s VM RAM increased: k3s-11 8→12 GB (balloon), k3s-12/13 8→16 GB (balloon)

### Removed
- Minio (replaced by Garage S3)
- NPM as primary reverse proxy (replaced by Traefik in k3s)
- Standalone Prometheus/Grafana Docker deployment (replaced by kube-prometheus-stack)
- MikroDash (decommissioned)
- Ansible roles for services now running in k3s: `authelia`, `vaultwarden`, `paperless`, `open_webui`, `minio`, `monitoring_core`, `atlantis`, `cloudflared`

## [0.4.0] — 2026-04

### Added
- Atlantis self-hosted GitOps runner deployed via Ansible on Docker LXC
- Cloudflare Tunnel for zero-inbound-port exposure of Atlantis webhook
- All Terraform changes now flow exclusively through pull requests
- `atlantis.yaml` repo config for automatic plan detection on PRs
- `ansible/requirements.yml` for declarative collection dependencies

### Changed
- All Ansible roles updated to use FQCN module names (`ansible.builtin.*`)
- All `yes`/`no` truthy values replaced with `true`/`false`
- `nginx-proxy-manager` role renamed to `nginx_proxy_manager` (lint compliance)
- Vault password rekeyed to remove special characters for CI compatibility

## [0.3.0] — 2026-03

### Added
- GitHub Actions CI pipeline (Terraform lint + validate, Ansible lint)
- Pre-commit hooks (`tflint`, `yamllint`, trailing whitespace, end-of-file)
- Architecture Decision Records: ADR-001 (Unbound), ADR-002 (Keepalived)
- Mermaid architecture diagram in README
- GitHub repo topics for discoverability

### Changed
- Repo structure standardised: `ansible/`, `terraform/stacks/`, `docker/`, `docs/`, `network/`

## [0.2.0] — 2025

### Added
- Monitoring stack: Prometheus + Grafana + node exporter + SNMP exporter for MikroTik
- Vaultwarden self-hosted password manager
- CrowdSec firewall bouncer on DMZ nodes
- MikroDash for MikroTik visibility
- Ansible Vault for secret management
- AdGuardHome-sync for replica state replication

### Changed
- Keepalived VIP configuration templated via Ansible
- Unbound recursive DNS tuned with kernel buffer optimisation

## [0.1.0] — 2025

### Added
- Initial repository structure
- MikroTik firewall rules managed via Terraform (routeros provider)
- Ansible roles: common, docker, watchtower, keepalived, adguard, unbound, nginx_proxy_manager
- Proxmox VE as hypervisor with LXC containers for workloads
- Raspberry Pi edge cluster with Keepalived Active/Passive VIP
- VLAN segmentation: Management, DMZ, Server
- WireGuard VPN for remote access
- Let's Encrypt wildcard certificates via DNS-01 (Cloudflare)
