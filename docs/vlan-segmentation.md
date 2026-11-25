# Network Segmentation Strategy

This document defines the logical network structure and security zones. The MikroTik RB5009 acts as the core router and stateful firewall, enforcing strict isolation.

## 1. VLAN Inventory

| VLAN ID | Name  | Subnet         | Gateway    | Primary Function |
| :--- | :--- | :--- | :--- | :--- |
| 10 | MGMT | 10.0.10.0/24 | 10.0.10.1 | Infrastructure Management (Proxmox host, PBS, Router API, Scanopy MGMT daemon). |
| 20 | SRV | 10.0.20.0/24 | 10.0.20.1 | Internal Services (AdGuard, Internal Proxy, Vaultwarden). |
| 30 | DMZ | 10.0.30.0/24 | 10.0.30.1 | Public-facing Services (External Reverse Proxy, Game Servers). |
| 40 | IOT | 10.0.40.0/24 | 10.0.40.1 | Untrusted / Smart Home Devices (Restricted Internet). |
| 100 | ADMIN | 10.0.100.0/24 | 10.0.100.1 | Trusted Administrative Workstations. |

## 2. Firewall Policies (Zero Trust)

* **Default Drop:** All inter-VLAN traffic is blocked at the end of the FORWARD chain.
* **Management Access:** Only the **ADMIN** zone is authorized to access the **MGMT** interfaces.
* **Router management:** SSH/WinBox/API only from `Mgmt_Devices` (VLAN 10 and 100); MAC-Telnet/MAC-WinBox only on the `mac-access` interface list, never ether1 (ADR-085).
* **WAN exposure:** TCP 443 to the DMZ proxy (headscale, with a per-source connection-flood guard) and UDP 41641 to rpi-srv-02 (Tailscale). Nothing on the router itself.
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

## 4. Address Allocation (VLAN 10 and 20)

Dynamic DHCP ranges stay clear of every static address and of MetalLB. Static
leases (`routeros_ip_dhcp_server_lease`) may sit outside the dynamic range.

| VLAN | Range | Use |
| :--- | :--- | :--- |
| 10 | `.10` | Proxmox host (static) |
| 10 | `.110`–`.111` | Static DHCP leases |
| 10 | `.150`–`.199` | Dynamic DHCP pool (`terraform/stacks/network/dhcp.tf`) |
| 20 | `.2`–`.13` | Raspberry Pis (static leases), AdGuard VIP `.5`, k3s API VIP `.10`, k3s nodes `.11`–`.13` |
| 20 | `.100` | NFS LXC |
| 20 | `.150`–`.199` | Dynamic DHCP pool (`terraform/stacks/network/dhcp.tf`) |
| 20 | `.200`–`.240` | MetalLB pool, minus `.205` (`kubernetes/system/metallb-config/pool.yml`) |
| 20 | `.205` | rybbit LXC (static) |
| 20 | `.250`–`.254` | Service LXCs (static, `.252` via static lease) |
