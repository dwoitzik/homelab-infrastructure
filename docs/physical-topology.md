# Physical Network Topology

This document describes the hardware interconnects and physical layer configuration.

## 1. Connectivity Map
| Source Device | Source Port | Target Device | Target Port | Cable Type | Speed |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Fritzbox 6591 | LAN 1 | MikroTik RB5009 | ether1 | Cat.6a | 1 Gbps |
| MikroTik RB5009 | ether2 | Admin Workstation | RJ45 | Cat.6a | 1 Gbps |
| MikroTik RB5009 | ether5 | Ryzen 7 (Proxmox) | RJ45 | Cat.7 | 1 Gbps (Trunk) |
| MikroTik RB5009 | ether6 | Raspberry Pi A | eth0 | Cat.7 | 1 Gbps |
| MikroTik RB5009 | ether7 | Raspberry Pi B | eth0 | Cat.7 | 1 Gbps |

## 2. Visual Representation

```mermaid
graph TD
    subgraph Public
        FB[Fritzbox 6591]
    end

    subgraph Core [MikroTik RB5009]
        FW[Firewall / Router]
    end

    subgraph Compute [Proxmox Node - Ryzen 7]
        PVE[PVE Host]
    end

    subgraph Infrastructure [Raspberry Pi Cluster]
        RPA[RPi A - Node 01]
        RPB[RPi B - Node 02]
    end

    FB ---|1G Uplink| Core
    Core ---|1G Access VLAN 100| Admin[Admin Workstation]
    Core ---|1G Trunk VLAN 10,20,30,40| PVE
    Core ---|1G Access VLAN 20| RPA
    Core ---|1G Access VLAN 20| RPB
