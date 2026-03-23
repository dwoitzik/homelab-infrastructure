# Infrastructure Nodes: Raspberry Pi Cluster

## Hardware Overview
| Component | Specification | Rationale |
| :--- | :--- | :--- |
| **Device** | 2x Raspberry Pi 4B | Low power consumption, perfect for 24/7 core services. |
| **RAM** | 8 GB | Significant headroom for Docker stacks and in-memory databases. |
| **Storage** | 128 GB SD Card | Plenty of space for logs and local container volumes. |
| **Network** | 1 GbE Ethernet | Attached to MikroTik `ether6` and `ether7` (VLAN 20). |

## Operating System
- **Distribution:** Raspberry Pi OS Lite (64-bit)
- **Base:** Debian Bullseye/Bookworm (Stable)
- **Rationale:** 64-bit is essential for modern container images and utilizes the ARMv8 architecture. "Lite" version minimizes the attack surface and resource overhead by omitting a GUI.

## Deployment Strategy
The nodes are managed via **Ansible** to ensure configuration parity.
Key services deployed:
1. **Keepalived:** High-Availability via VRRP (Virtual IP).
2. **AdGuard Home:** Network-wide DNS blocking.
3. **Nginx Proxy Manager:** Centralized SSL management and reverse proxy.

## High Availability (HA) Logic
We use two physical nodes to prevent a "Single Point of Failure" (SPoF) for core network services (DNS/Proxy). If `pi-node-01` fails, the Virtual IP automatically migrates to `pi-node-02`.
