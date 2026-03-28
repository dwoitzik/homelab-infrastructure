# Network Segmentation Strategy

This document defines the logical network structure and security zones. The MikroTik RB5009 acts as the core router and stateful firewall, enforcing strict isolation.

## 1. VLAN Inventory
| VLAN ID | Name  | Subnet         | Gateway    | Primary Function |
| :--- | :--- | :--- | :--- | :--- |
| 10 | MGMT | 10.0.10.0/24 | 10.0.10.1 | Infrastructure Management (Proxmox host, PBS, Router API). |
| 20 | SRV | 10.0.20.0/24 | 10.0.20.1 | Internal Services (AdGuard, Internal Proxy, Vaultwarden). |
| 30 | DMZ | 10.0.30.0/24 | 10.0.30.1 | Public-facing Services (External Reverse Proxy, Game Servers). |
| 40 | IOT | 10.0.40.0/24 | 10.0.40.1 | Untrusted / Smart Home Devices (Restricted Internet). |
| 100 | ADMIN | 10.0.100.0/24 | 10.0.100.1 | Trusted Administrative Workstations. |

## 2. Firewall Policies (Zero Trust)
* **Default Drop:** All inter-VLAN traffic is blocked at the end of the FORWARD chain.
* **Management Access:** Only the **ADMIN** zone is authorized to access the **MGMT** interfaces.
* **DMZ Isolation:** The **DMZ** can only respond to established traffic and reach the WAN. Lateral movement to internal segments is hard-dropped.
* **Proxy Pinholing:** Specific pinholes exist for the External Proxy (DMZ) to reach designated internal backends on defined ports (80/443).

## 3. Physical Port Configuration (MikroTik RB5009)
| Interface | Device / Link | Mode | Tagged/PVID |
| :--- | :--- | :--- | :--- |
| ether1 | WAN (Fritzbox 6591) | DHCP-Client | - |
| ether2 | Admin Workstation | Access | 100 |
| ether5 | Proxmox Core (Ryzen 7) | Trunk | 10, 20, 30, 40 |
| ether6 | Raspberry Pi A | Access | 20 |
| ether7 | Raspberry Pi B | Access | 20 |
| ether3,4,8| - | *Free* | - |
