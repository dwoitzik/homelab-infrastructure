# Network Segmentation Strategy

This document defines the logical network structure and security zones. The MikroTik RB5009 acts as the core router and firewall, enforcing isolation between functional segments.

## 1. VLAN Inventory

The network utilizes a consistent `10.0.X.0/24` addressing scheme for clarity and management.

| VLAN ID | Name  | Subnet         | Gateway    | Primary Function |
| :--- | :--- | :--- | :--- | :--- |
| 10 | MGMT | 10.0.10.0/24 | 10.0.10.1 | Infrastructure Management (Proxmox, MikroTik, PIs). |
| 20 | SRV | 10.0.20.0/24 | 10.0.20.1 | Internal Services (Non-public, e.g., Databases, Vaultwarden). |
| 30 | DMZ | 10.0.30.0/24 | 10.0.30.1 | Public-facing Services (Reverse Proxy, Game Servers). |
| 40 | IOT | 10.0.40.0/24 | 10.0.40.1 | Untrusted / Smart Home Devices (Restricted Internet). |
| 100 | ADMIN | 10.0.100.0/24 | 10.0.100.1 | Trusted Administrative Workstations. |

## 2. Default Firewall Policies

* **Default Drop:** All inter-VLAN traffic is blocked unless explicitly permitted.
* **Management Access:** Only the **ADMIN** zone is authorized to access the **MGMT** interfaces of all hardware.
* **DMZ Isolation:** The **DMZ** can only respond to established traffic and reach the WAN; it cannot initiate connections to internal segments.
* **IoT Restriction:** Devices in the **IOT** zone are isolated from all other internal networks and have throttled WAN access.

## 3. Physical Port Configuration (MikroTik RB5009)

| Interface | Device / Link | Mode | Tagged/PVID |
| :--- | :--- | :--- | :--- |
| ether1 | WAN (Fritzbox 6591) | DHCP-Client | - |
| ether2 | Admin PC | Access | 100 |
| ether3 | - | *Free* | - |
| ether4 | - | *Free* | - |
| ether5 | Proxmox Core (Ryzen 7) | Trunk | 10, 20, 30, 40 |
| ether6 | Raspberry Pi A | Access | 10 |
| ether7 | Raspberry Pi B | Access | 10 |
| ether8 | - | *Free* | - |
