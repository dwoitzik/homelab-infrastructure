# Naming Convention

To ensure scalability and clarity within the homelab, a standardized naming convention is applied to all physical hosts, virtual machines, and containers.

## Schema
`[Type]-[Zone]-[Index]`

### Types
- **rpi**: Physical Raspberry Pi hardware.
- **pve**: Proxmox Virtual Environment host.
- **vm**: Virtual Machine running on Proxmox.
- **ct**: Linux Container (LXC) running on Proxmox.

### Zones (VLANs) & Proxmox ID Routing
To maintain strict organization, Proxmox Container and VM IDs are directly mapped to their respective VLANs.

| Range | VLAN ID | Zone | Description |
| :--- | :--- | :--- | :--- |
| `100 - 199` | 10 | `mgmt` | Management Network & Infrastructure Core |
| `200 - 299` | 20 | `srv` | Internal Services & Databases |
| `300 - 399` | 30 | `dmz` | Demilitarized Zone (Public facing) |
| `400 - 499` | 40 | `iot` | Internet of Things & Smart Home |
| `900 - 999` | 100 | `admin` | Restricted Admin Access |

### DNS & Subdomain Routing
Internal and external services follow a strict CNAME/A-Record naming convention mapped to the root domain (`woitzik.dev`).

* **Core Infrastructure:** `[hostname].woitzik.dev` (e.g., `pve-mgmt-01.woitzik.dev`, `router.woitzik.dev`)
* **Core Services:** `[service].woitzik.dev` (e.g., `dns.woitzik.dev`, `proxy.woitzik.dev`)
* **User Applications:** `[app-name].woitzik.dev` (e.g., `vault.woitzik.dev`, `photos.woitzik.dev`)

## Examples
| ID | Hostname | DNS Record | Description |
| :--- | :--- | :--- | :--- |
| `100`| `pve-mgmt-01` | `pve-mgmt-01.woitzik.dev` | Primary Proxmox Node. |
| `301`| `vm-dmz-proxy-01` | `proxy.woitzik.dev` | Nginx Proxy Manager. |
| `200`| `ct-srv-docker-01`| `vault.woitzik.dev` | Docker host running Vaultwarden. |
