# 📦 Kubernetes Applications

This directory houses the manifests for applications deployed on the K3s cluster. The deployment follows a GitOps pattern, ensuring all application states are declaratively defined and automatically synchronized.

## 🔑 Shared Security Patterns

### 1. Identity & SSO
Applications are integrated into a centralized identity layer using **Authelia**. Where supported, OIDC is used for full SSO. For legacy apps, Traefik's `ForwardAuth` middleware ensures that only authenticated users can reach the service.

### 2. Secret Management
Passwords and sensitive API tokens are abstracted into Kubernetes `Secrets`. This ensures that deployment manifests can be safely shared while keeping actual credentials controlled.

### 3. Persistent Storage
Persistence is provided by **Longhorn**, allowing for distributed, replicated block storage. This enables high availability for stateful applications across the cluster nodes.

## 🚀 Deployed Services

- **Authelia**: Central Identity & OIDC Provider.
- **Paperless-ngx**: Document management system with Postgres/Redis backend.
- **Minio**: S3-compatible object storage with OIDC integration.
- **Vaultwarden**: Bitwarden-compatible password manager.
- **Open-WebUI**: Local LLM interface.
- **Mikrodash**: Monitoring dashboard for MikroTik routers.
