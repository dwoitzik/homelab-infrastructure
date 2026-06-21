# Naming Convention

Every physical host, VM, and container follows the same naming pattern, so I can tell what something is and where it lives just from the name.

## Schema
`[Type]-[Zone]-[Service]-[Index]`

### Types
- **rpi**: Physical Raspberry Pi hardware.
- **pve**: Proxmox Virtual Environment host.
- **vm**: Virtual Machine.
- **ct**: Linux Container (LXC).

### Zones & ID Routing
Proxmox Container and VM IDs are mapped to their respective VLANs.
| Range | VLAN ID | Zone | Description |
| :--- | :--- | :--- | :--- |
| `100 - 199` | 10 | `mgmt` | Infrastructure Core |
| `200 - 299` | 20 | `srv` | Internal Services |
| `300 - 399` | 30 | `dmz` | Demilitarized Zone |
| `900 - 999` | 100 | `admin` | Admin Access |

### Examples (Including Dual-Proxy Architecture)
| ID | Hostname | Description |
| :--- | :--- | :--- |
| `100`| `pve-mgmt-01` | Primary Proxmox Node. |
| `110`| `ct-mgmt-pbs-01` | Proxmox Backup Server. |
| `200`| `ct-srv-docker-01`| Internal Docker host (Vaultwarden). |
| `-`  | `rpi-srv-proxy-01`| Internal Nginx Proxy Manager (RPi). |
| `301`| `ct-dmz-proxy-01` | External Nginx Proxy Manager (DMZ). |
