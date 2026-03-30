# Homelab Infrastructure as Code

Configuration and documentation for a highly available, secure homelab environment. This project manages the lifecycle of local hardware, network routing, and integrated cloud services entirely through automated Infrastructure as Code (IaC) workflows.

## 🛠️ Infrastructure Stack
* **Hypervisor:** Proxmox VE (Ryzen 7 5725U)
* **Networking:** MikroTik RB5009 (RouterOS)
* **Edge Nodes:** 2x Raspberry Pi 4B (Debian)
* **Reverse Proxy & SSL:** Nginx Proxy Manager (NPM)
* **DNS & Ad-Blocking:** AdGuard Home + Unbound (Recursive DNS)
* **Cloud Governance:** Microsoft Azure (Arc-enabled)

graph TB
    subgraph cloud["☁️ Cloud & External"]
        NET([Internet])
        CF["Cloudflare DNS\nDNS-01 · *.woitzik.dev"]
        AZ["Microsoft Azure\nArc-enabled governance"]
    end

    subgraph router["🔀 Network Layer"]
        MK["MikroTik RB5009\nVLAN isolation · zero-trust firewall · hairpin NAT"]
        VLAN["VLAN Zones\nMgmt · DMZ · Server · IoT"]
    end

    subgraph compute["🖥️ Compute"]
        PVE["Proxmox VE\nRyzen 7 5725U · VM + LXC host"]
        DOCKER["Docker Services\nNginx Proxy Manager · apps by zone"]
    end

    subgraph edge["🍓 Edge Cluster — Keepalived VIP"]
        RPI1["RPi 4B — primary\nAdGuard · Unbound · NPM"]
        RPI2["RPi 4B — replica\nAdGuard sync · standby"]
        VIP(["Virtual IP\nActive/Passive failover"])
    end

    subgraph dns["🔍 DNS Resolution Chain"]
        AGH["AdGuard Home\nfiltering + ad-block"]
        UB["Unbound\nrecursive resolver"]
        ROOT(["Root DNS servers\nno upstream dependency"])
    end

    subgraph iac["⚙️ Automation & IaC"]
        TF["Terraform\nProxmox · MikroTik · Cloudflare"]
        AN["Ansible\nRoles · Vault · HA cluster"]
        GHA["GitHub Actions\ntflint · yamllint · validate"]
        PC["pre-commit\nlocal lint + checks"]
    end

    NET --> MK
    CF -. "wildcard cert" .-> MK
    AZ -. "Arc agent" .-> PVE
    MK --> VLAN
    MK --> PVE
    MK --> RPI1
    PVE --> DOCKER
    DOCKER --> RPI1
    RPI1 -. "sync" .-> RPI2
    RPI1 --> VIP
    RPI2 --> VIP
    RPI1 --> AGH
    AGH --> UB
    UB --> ROOT
    iac -. "provisions & configures" .-> compute
    iac -. "provisions & configures" .-> edge
    iac -. "provisions & configures" .-> router

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
