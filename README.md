# Homelab Infrastructure as Code

Configuration and documentation for a highly available, secure homelab environment. This project manages the lifecycle of local hardware, network routing, and integrated cloud services entirely through automated Infrastructure as Code (IaC) workflows.

## 🛠️ Infrastructure Stack
* **Hypervisor:** Proxmox VE (Ryzen 7 5725U)
* **Networking:** MikroTik RB5009 (RouterOS)
* **Edge Nodes:** 2x Raspberry Pi 4B (Debian)
* **Reverse Proxy & SSL:** Nginx Proxy Manager (NPM)
* **DNS & Ad-Blocking:** AdGuard Home + Unbound (Recursive DNS)
* **Cloud Governance:** Microsoft Azure (Arc-enabled)

## 📁 Repository Layout
* `/network`: Logical topology, VLAN definitions, and RouterOS firewall/NAT configurations via Terraform.
* `/terraform`: Infrastructure provisioning for Proxmox, MikroTik routing, and Cloudflare DNS.
* `/ansible`: Idempotent configuration management for server nodes, Docker environments, and high-availability clustering.
* `/docker`: Container specifications organized by network zone.
* `/docs`: Technical design decisions and architectural guides.

## 🚀 Core Architectural Concepts

### 1. High Availability & Clustering
* **Keepalived VIP:** Active/Passive failover utilizing a Virtual IP (VIP) across the Raspberry Pi edge nodes to ensure zero-downtime DNS and Proxy services.
* **State Synchronization:** Automated replication of AdGuard Home configurations across primary and replica nodes using `adguardhome-sync`.

### 2. Privacy-First DNS Resolution
* **Recursive DNS:** Implementation of Unbound as a local, recursive DNS resolver to eliminate reliance on third-party upstream providers.
* **Kernel Optimization:** Tuned kernel network buffers via Ansible to maximize UDP/TCP throughput for high-volume DNS queries.

### 3. Advanced Networking & Security
* **Zone Isolation:** Strict VLAN-based network segmentation isolating Management, DMZ, Server, and IoT traffic.
* **Zero-Trust Firewalling:** MikroTik forward/input chains explicitly dropping unauthorized inter-VLAN traffic.
* **Hairpin NAT:** Resolved asymmetric routing scenarios to allow upstream clients seamless access to internal VIPs.
* **Automated SSL:** Let's Encrypt wildcard certificates (`*.woitzik.dev`) managed via DNS-01 challenges (Cloudflare), eliminating the need for exposed inbound HTTP ports.

### 4. Automation & Workflows
* **Idempotent Playbooks:** Ansible roles designed for repeatable, safe execution using handlers and cache validation.
* **CI/CD:** GitHub Actions for code linting and infrastructure validation.
