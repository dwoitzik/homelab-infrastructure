# 🗺️ Migration Roadmap: Docker to K3s

Goal: Move all "islands" of standalone Docker Compose stacks into the coordinated K3s cluster to eliminate manual proxy management (NPM UI) and gain high availability.

## 1. Status Overview

| Service | Current Host | Status | Target |
| :--- | :--- | :--- | :--- |
| **Vaultwarden** | `vm-srv-k3s` | ✅ Migrated | K3s (with Longhorn) |
| **Authelia** | `vm-srv-k3s` | ✅ Migrated | K3s |
| **Paperless-ngx** | `ct-srv-docker-01` | ⏳ Pending | K3s |
| **Minio** | `ct-srv-docker-01` | ⏳ Pending | K3s |
| **Open-WebUI** | `ct-srv-docker-01` | ⏳ Pending | K3s |
| **AdGuard / Unbound** | `rpi-srv-01/02` | 🔒 Static | Keep on RPis (Core Net) |

## 2. Migration Procedure (Generic)

1.  **Preparation:**
    *   Create directory in `kubernetes/apps/<service>/`.
    *   Define `Deployment`, `Service`, `PVC` (Longhorn), and `Ingress`.
2.  **Data Sync:**
    *   Stop the legacy Docker container.
    *   `rsync` data from `/opt/docker/<service>` to a temporary migration pod in K3s.
3.  **Activation:**
    *   Add the app to ArgoCD.
    *   Verify the `*.woitzik.dev` ingress and Authelia protection.
4.  **Cleanup:**
    *   Remove the legacy Ansible role and Docker stack.

## 3. Future Expansion: K3s on RPis
- **Plan:** Install K3s (Agent) on `rpi-srv-01` and `rpi-srv-02`.
- **Constraint:** Use node taints to prevent Longhorn from scheduling replicas on SD cards.
- **Benefit:** Allows running lightweight cluster-critical pods (like `external-dns` or `cloudflared`) on low-power hardware that stays up during PVE maintenance.
