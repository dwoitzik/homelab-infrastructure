# Changelog

All notable changes to this infrastructure are documented here.

## [Unreleased]

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
