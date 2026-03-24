# Infrastructure Nodes: Raspberry Pi Cluster

## Hardware Overview
| Component | Specification | Rationale |
| :--- | :--- | :--- |
| **Device** | 2x Raspberry Pi 4B | Low power consumption, perfect for 24/7 core services. |
| **RAM** | 8 GB | Significant headroom for Docker stacks and in-memory databases. |
| **Storage** | 256 GB SD Card | Plenty of space for logs and local container volumes. |
| **Network** | 1 GbE Ethernet | Attached to MikroTik `ether6` and `ether7` (VLAN 20). |

## Operating System & Hardening
- **Distribution:** Raspberry Pi OS Lite (64-bit) based on Debian Bookworm.
- **Security:** Automatic security patches enabled via `unattended-upgrades`.
- **Docker:** Installed using the modern GPG-keyring method (`/etc/apt/keyrings`) for maximum repository security.

## Deployment Strategy
The nodes are managed via **Ansible** to ensure configuration parity and idempotency.
Key services deployed:
1. **Keepalived:** High-Availability via VRRP (Virtual IP `10.0.20.5`).
2. **AdGuard Home:** Network-wide DNS blocking (Deployed).
3. **Unbound:** Recursive DNS resolution (Deployed).
4. **Nginx Proxy Manager:** Centralized SSL management (In Progress).

## High Availability (HA) Logic
We use two physical nodes to prevent a "Single Point of Failure" (SPoF).
- **Protocol:** VRRP (Virtual Router Redundancy Protocol).
- **Behavior:** If the primary node (`rpi-srv-01`) goes offline, the Virtual IP automatically migrates to the backup node (`rpi-srv-02`) within seconds, ensuring zero downtime for DNS and proxy services.

## DNS & Security Stack
We use a layered DNS approach to ensure privacy, speed, and high availability.

| Service | Technology | Role |
| :--- | :--- | :--- |
| **AdGuard Home** | Docker | Primary DNS sinkhole (Ad-blocking & UI). |
| **Unbound** | Docker | Recursive DNS resolver (no upstream logging). |
| **Watchtower** | Docker | Automated container updates and maintenance. |
| **Keepalived** | VRRP | Virtual IP management (10.0.20.5) for DNS failover. |

### Recursive DNS Flow
Instead of forwarding requests to Google or Cloudflare, our cluster resolves queries directly via the Global Root Servers:
`Client -> AdGuard Home (VIP) -> Unbound (Local) -> Root Servers`

### Automatic Synchronization
Configuration changes on `rpi-srv-01` are automatically synced to `rpi-srv-02` every 5 minutes using `adguardhome-sync`, ensuring both nodes share the same filter lists and DNS rewrites.
