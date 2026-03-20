# Homelab Infrastructure as Code

Configuration and documentation for a homelab environment. This project manages the lifecycle of local hardware and integrated cloud services through automated workflows.

## Infrastructure Stack
* **Hypervisor:** Proxmox VE (Ryzen 7 5725U)
* **Networking:** MikroTik RB5009 (RouterOS)
* **Edge Nodes:** 2x Raspberry Pi 4B (Debian)
* **Cloud Governance:** Microsoft Azure (Arc-enabled)

## Repository Layout
* `/network`: Logical topology, VLAN definitions, and RouterOS configurations.
* `/terraform`: Infrastructure provisioning for Proxmox and Cloudflare.
* `/ansible`: Configuration management for server nodes and applications.
* `/docker`: Container specifications organized by network zone.
* `/docs`: Technical design decisions and architectural guides.

## Core Concepts
* **Zone Isolation:** Strict VLAN-based network segmentation.
* **Security:** DNS-01 SSL challenges via Cloudflare; WireGuard for remote administration.
* **Automation:** CI/CD via GitHub Actions for linting and validation.
