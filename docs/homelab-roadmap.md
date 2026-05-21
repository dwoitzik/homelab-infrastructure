# 🗺️ Homelab Roadmap

This document tracks the planned expansion and enhancements for the homelab infrastructure.

## 🏗️ Core Foundation (Completed)
- [x] **K3s Cluster**: Highly available control plane on Proxmox, workers on Raspberry Pis.
- [x] **GitOps**: Atlantis (Terraform) and ArgoCD (Kubernetes) fully operational.
- [x] **SSO/OIDC**: Authelia integrated with Proxmox, PBS, Minio, and ArgoCD.
- [x] **Storage**: Longhorn distributed block storage.
- [x] **Networking**: MikroTik RB5009 with VLAN isolation and Cloudflare Tunnels.

## 📈 Phase 1: Observability & Security (In Progress)
- [x] **Uptime Kuma**: Monitoring all services with automated alerts.
    - Status: Firewall rules `fwd_04a` and `in_02a` applied to allow monitoring reachability.
- [x] **Headscale (Management VPN)**: Self-hosted Tailscale control plane for portless remote access.
    - Status: Deployed and configured with internal DNS (AdGuard).
- [x] **Centralized Logging (Loki + Promtail)**: Log aggregation in Grafana.
    - Status: Fully operational with 30d retention in Garage S3.
- [x] **Automated Updates (Renovate + Keel)**:
    - Status: Keel managing image updates; Renovate configured for repo-wide dependency tracking.
- [x] **Velero**: Backup automation for K3s resources to Garage S3.
    - Status: Manifests and Schedules defined in `kubernetes/system/velero/`.

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
