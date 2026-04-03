# Changelog

All notable changes to this infrastructure are documented here.

## [Unreleased]

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
- VLAN segmentation: Management, DMZ, Server, IoT, Admin
- WireGuard VPN for remote access
- Let's Encrypt wildcard certificates via DNS-01 (Cloudflare)
