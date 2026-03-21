# Physical Network Topology

This document describes the hardware interconnects and physical layer configuration of the infrastructure.

## 1. Physical Connectivity Map

| Source Device | Source Port | Target Device | Target Port | Cable Type |
| :--- | :--- | :--- | :--- | :--- |
| Fritzbox 6591 | LAN 1 | MikroTik RB5009 | ether1 | 1 Gbps | Cat.6a |
| MikroTik RB5009 | ether2 | Admin Workstation | RJ45 | 1 Gbps | Cat.6a |
| MikroTik RB5009 | ether5 | Ryzen 7 (Proxmox) | RJ45 | 10 Gbps* | Cat.7 |
| MikroTik RB5009 | ether6 | Raspberry Pi A | RJ45 | 10 Gbps* | Cat.7 |
| MikroTik RB5009 | ether7 | Raspberry Pi B | RJ45 | 10 Gbps* | Cat.7 |

*\*Note: Links are cabled for 10 Gbps to ensure future-proofing. Actual negotiated speeds depend on the connected NICs (currently 1G on all devices).*

## 2. Hardware Roles & Storage

### Core Compute (Ryzen 7 5725U)
* **Storage A:** 512GB NVMe (OS & VM Local Storage)
* **Storage B:** 2TB External HDD (USB 3.0) - Mounted for Backups/Media.
* **Storage C:** 512GB USB Stick - Temp / ISO Staging.

### Infrastructure Nodes (Raspberry Pis)
* Dedicated to lightweight, high-availability services (DNS, Keepalived).
* Powered via USB-C.

## 3. Visual Representation
```mermaid
graph TD
    subgraph Public_Zone
        FB[Fritzbox 6591]
    end

    subgraph Core_Network
        MT[MikroTik RB5009]
    end

    subgraph Compute_Nodes
        PVE[Proxmox Node - Ryzen 7]
        RPA[Raspberry Pi A]
        RPB[Raspberry Pi B]
    end

    FB ---|1G Uplink| MT
    MT ---|1G Access| Admin[Admin Workstation]
    MT ---|10G Trunk| PVE
    MT ---|10G Access| RPA
    MT ---|10G Access| RPB

    subgraph Storage
        HDD[2TB External HDD]
        USB[512GB USB Stick]
    end

    PVE ---|USB 3.0| HDD
    PVE ---|USB 3.0| USB
