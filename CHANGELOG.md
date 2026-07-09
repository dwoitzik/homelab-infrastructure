# Changelog

All notable changes to this infrastructure are documented here.

## [Unreleased]

## [0.8.0] — 2026-06-28

### Added

- **Cloudflare TF provider v5** (PR #192): migrated `terraform/stacks/cloudflare/` from `~> 4.0`
  to `~> 5.0` with `moved {}` blocks to rename existing state resources without destroying/recreating
  the live tunnel or DNS record:
  - `cloudflare_tunnel_config` → `cloudflare_zero_trust_tunnel_cloudflared_config`
  - `cloudflare_record` → `cloudflare_dns_record` (`value` field renamed to `content`)
- **Immich upload fix** (PR #192): added `chunked_encoding = true`, `write_timeout = 600s`,
  `read_timeout = 120s` to Cloudflare Tunnel origin config — fixes ECONNRESET for large photo/video
  uploads that previously failed mid-transfer

### Fixed

- **Pinned all remaining floating image tags** (PR #193): `valkey/valkey:9-alpine` → `9.1.0-alpine`,
  `gotenberg/gotenberg:8` → `8.34.0`, `ghcr.io/renovatebot/renovate:43` → `43.245.0`,
  `gitea/gitea:1.26` → `1.26.4`, `hashicorp/vault:1.21` → `1.21.4`,
  `ghcr.io/home-assistant/home-assistant:stable` → `2026.6.4`,
  `ghcr.io/open-webui/open-webui:main` → `v0.9.6`, `alpine:3` → `3.22`.
- Closed Renovate's auto-PR #167 (Cloudflare v5) as superseded by the manual migration (#192)

---

## [0.7.0] — 2026-06-28

### Added

- **Immich v2.7.5** — fresh install replacing v1.109.2 (PR #174):
  - PostgreSQL switched from `tensorchord/pgvecto-rs:pg16` to `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` (VectorChord, PG14, no custom args)
  - Redis replaced by `valkey/valkey:9-alpine`; RDB+AOF disabled (`--save "" --appendonly no`) to run in-memory with `readOnlyRootFilesystem: true` (PR #188)
  - Server and ML both on v2.7.5; server port changed 3001 → 2283
  - `HF_HOME=/cache/huggingface` and `XDG_CACHE_HOME=/cache/xdg` added to immich-ml to redirect HuggingFace xet downloads to writable PVC (PR #190)
- **Cloudflare Tunnel for Immich** — `photos.woitzik.dev` now externally accessible for family photo backup (PR #165):
  - New Terraform stack `terraform/stacks/cloudflare/` with Cloudflare provider v4, `cloudflare_tunnel_config` and DNS CNAME record
  - Cloudflare API token stored in Ansible Vault, injected into Atlantis via `atlantis-secrets` k8s Secret
  - AdGuard split-DNS: `photos.woitzik.dev` overrides the `*.woitzik.dev → 10.0.20.200` wildcard with Cloudflare anycast A records (`172.67.137.91`, `104.21.38.184`)
  - ADR-011 documents the external access decision
- **Renovate Kubernetes manager** — container images in `kubernetes/` now tracked and PRs opened for updates (PR #168). Previously only Helm/Terraform were active; 93 images were invisible to Renovate
- **Pinned floating image tags** — bulk PR #187 converts major-only floats to semver:
  - `louislam/uptime-kuma:1` → `1.23.17`
  - `redis:7-alpine` → `7.4.9-alpine`; `redis:7` → `7.4.9`
  - `postgres:16` → `16.14`; `postgres:16-alpine` → `16.14-alpine`
  - `nextcloud:30-apache` → `30.0.17-apache`
- `renovate.json` — new file at repo root configuring Kubernetes image tracking with grouping rules for major updates

### Fixed

- Removed dead `keel.sh/policy: force` / `keel.sh/trigger: poll` annotations from uptime-kuma (Keel is not deployed; annotations conflicted with ArgoCD selfHeal in theory)
- Valkey startup race: `stop-writes-on-bgsave-error` was triggering immediately on Immich startup because Valkey tries to write RDB snapshots with no writable data directory

### Security

- Cloudflare Tunnel token (`cfut_5NVF…`) stored in Ansible Vault (`cloudflare_api_token`), not in Git (PR #165)

## [0.6.0] — 2026-06-21

### Added

- k3s HA: all 3 nodes run control-plane + embedded etcd (migrated from single-node SQLite, no rebuild)
- k3s API VIP (`10.0.20.10`) via Keepalived
- Vault auto-unseal sidecar — no more manual unseal after a restart
- Independent DNS health check on both RPis (Discord alert, no dependency on k3s/Prometheus)
- Hardware watchdog on both RPis (BCM overlay + systemd)
- Host firewall (nftables) on both RPis for natively-bound services
- fail2ban on both RPis
- Per-container memory limits on RPi Docker workloads
- Local rotating config backup for RPi DNS configs (PBS/Velero don't cover physical hosts)
- Docker log size cap, daemon-wide
- Gitleaks scanning: pre-commit, pre-push, CI
- MikroTik service hardening (telnet/ftp disabled, api/api-ssl scoped to internal networks)
- Cloudflare R2 offsite Velero backup location (pending credentials)
- Cobblemon Minecraft server, routed through the existing DMZ proxy/CrowdSec setup
- Cloudflare DDNS CronJob for `cobblemon.woitzik.dev`
- `docs/secrets-inventory.md`, `docs/OPERATIONS.md`

### Fixed

- Velero daily backup was missing `defaultVolumesToFsBackup` — backups looked fine but never captured actual PVC data
- NetworkPolicy default-deny rollout had broken Velero→Garage and Homepage→Uptime Kuma without anyone noticing
- AdGuard was flooding PTR queries to the Fritzbox for the k3s pod network, which can't answer them
- AdGuard's Ansible template had drifted from the live config — rebuilt it, recovered 3 DNS rewrites that only existed in the web UI
- Traefik's ArgoCD sync was broken for over a day (Helm schema mismatch)
- ArgoCD repo-server cache staleness was reverting kubectl changes within seconds
- paperless-gpt defaulted to English regardless of document language
- Proxmox host kept freezing on boot — staggered VM/LXC startup order fixed the resource storm; a second freeze turned out to be dried-out thermal paste, not software
- ansible-lint locally was 20 versions behind CI, which is why lint passed locally and failed in CI

### Removed

- `processor.max_cstate=1 idle=nomwait` kernel param — was a guess at fixing the Proxmox freezes, made idle temps worse, reverted
- 36 duplicate/orphaned MikroTik firewall rules left behind by past firewall rewrites — some of the old broad rules were still winning over newer, tighter ones
- Renewed the MikroTik's self-signed CA, which was 5 weeks from expiry (would have broken HTTPS to the router regardless of the leaf cert's own 2035 expiry)
- Fixed rpi-srv-02 reporting its hostname as rpi-srv-01 — both Pis were indistinguishable in logs by hostname alone

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
