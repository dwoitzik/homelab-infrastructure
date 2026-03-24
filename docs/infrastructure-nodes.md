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
2. **AdGuard Home:** Network-wide DNS blocking (Planned).
3. **Nginx Proxy Manager:** Centralized SSL management (Planned).

## High Availability (HA) Logic
We use two physical nodes to prevent a "Single Point of Failure" (SPoF).
- **Protocol:** VRRP (Virtual Router Redundancy Protocol).
- **Behavior:** If the primary node (`rpi-srv-01`) goes offline, the Virtual IP automatically migrates to the backup node (`rpi-srv-02`) within seconds, ensuring zero downtime for DNS and proxy services.
