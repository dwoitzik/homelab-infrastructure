# 🗺️ Homelab Roadmap

This document tracks the planned expansion and enhancements for the homelab infrastructure.

## 🏗️ Core Foundation (Completed)
- [x] **K3s Cluster**: Highly available control plane on Proxmox, workers on Raspberry Pis.
- [x] **GitOps**: Atlantis (Terraform) and ArgoCD (Kubernetes) fully operational.
- [x] **SSO/OIDC**: Authelia integrated with Proxmox, PBS, Minio, and ArgoCD.
- [x] **Storage**: Longhorn distributed block storage.
- [x] **Networking**: MikroTik RB5009 with VLAN isolation and Cloudflare Tunnels.

## 📈 Phase 1: Observability & Security (In Progress)
- [ ] **Uptime Kuma**: Monitoring all services with automated alerts.
    - Target: Raspberry Pi node (VLAN 20).
    - Status: Deployment complete, waiting for firewall apply and Cloudflare route.
- [x] **Centralized Logging (Loki + Promtail)**: Log aggregation in Grafana.
    - Status: Installed and connected to Grafana & Minio.
- [ ] **Automated Updates (Renovate + Keel)**:
    - **Renovate**: Automatically creates PRs for outdated Docker images and Terraform providers.
    - **Keel**: Automatically restarts K3s pods when new image versions are pushed (the K8s equivalent of Watchtower).
- [ ] **Velero**: Backup automation for K3s resources to Minio S3.

## 📂 Phase 2: Data & Cloud
- [ ] **Seafile**: Private cloud storage with Minio S3 backend.
- [ ] **Kasm Workspaces**: Isolated browser/desktop environments for secure browsing.

## 🎬 Phase 3: Media & Automation (The "Arr" Stack)
- [ ] **Servarr Stack**: Radarr, Sonarr, Prowlarr, and SABnzbd.
- [ ] **Overseerr**: Discovery and request management frontend.
- [ ] **Jellyfin**: Media server (running on Proxmox LXC for GPU passthrough).

## 🏠 Phase 4: Smart Home
- [ ] **Home Assistant**: Migration to a dedicated VM for hardware stability.
- [ ] **Zigbee2MQTT / ESPHome**: Integrated into the K3s network.

---
*Last Updated: May 18, 2026*
