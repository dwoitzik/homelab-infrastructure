# 🚀 Homelab Migration & Architecture

This repository contains the Infrastructure as Code (IaC) and GitOps definitions for my highly available homelab environment. The architecture is transitioning from standalone Docker nodes to a unified **K3s Kubernetes cluster** to gain professional-grade orchestration, observability, and security.

## 🏗️ Technical Stack

- **Orchestration**: K3s (Kubernetes) managed via ArgoCD.
- **GitOps**: Atlantis (Terraform) and ArgoCD (Kubernetes).
- **Security**: Authelia SSO with OIDC, Traefik ForwardAuth, and WireGuard.
- **Storage**: Longhorn distributed block storage.
- **Networking**: MikroTik RB5009, Traefik Ingress, and Cloudflare Tunnels.
- **Monitoring**: Prometheus, Grafana, and SNMP for network metrics.

## 🗺️ Migration Progress

The following core services have been migrated from legacy Docker LXCs to the K3s cluster:
- **Identity**: Authelia (OIDC Provider)
- **Productivity**: Paperless-ngx
- **Storage**: Minio (S3 API)
- **Security**: Vaultwarden
- **AI**: Open-WebUI
- **Network**: Mikrodash

## 🔒 Security Architecture

The environment uses a zero-trust approach where internal services are protected by **Authelia**. SSO is implemented via OIDC for major infrastructure components:
- **Proxmox VE**: Integrated via Authelia OIDC.
- **Argo CD**: SSO enabled for administrative access.
- **Minio**: S3 Console secured with OIDC.
- **Grafana**: Automated login via Authelia headers.

## 📂 Repository Layout

- `kubernetes/`: System-level and application manifests.
- `ansible/`: Base OS provisioning and edge node management.
- `terraform/`: Infrastructure provisioning (Proxmox, MikroTik, Cloudflare).
- `docs/`: Architecture Decision Records (ADR) and roadmap.
