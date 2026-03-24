# Naming Convention

To ensure scalability and clarity within the homelab, a standardized naming convention is applied to all physical hosts, virtual machines, and containers.

## Schema
`[Type]-[Zone]-[Index]`

### Types
- **rpi**: Physical Raspberry Pi hardware.
- **pve**: Proxmox Virtual Environment host.
- **vm**: Virtual Machine running on Proxmox.
- **ct**: Linux Container (LXC) running on Proxmox.

### Zones (VLANs)
- **mgmt**: Management Network (VLAN 10)
- **srv**: Internal Services / Server Network (VLAN 20)
- **dmz**: Demilitarized Zone / External facing (VLAN 30)
- **iot**: Internet of Things (VLAN 40)
- **admin**: Restricted Admin Access (VLAN 100)

## Examples
| Hostname | Description |
| :--- | :--- |
| `rpi-srv-01` | First Raspberry Pi in the Server VLAN. |
| `pve-mgmt-01` | Primary Proxmox Node in the Management VLAN. |
| `vm-dmz-proxy-01` | Nginx Proxy Manager VM in the DMZ. |
| `ct-srv-db-01` | Database Container in the Server Network. |
