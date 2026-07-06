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

Re-verified 2026-07-06 -- 2 rows below were stale and corrected.

| ID | Hostname | Description |
| :--- | :--- | :--- |
| `100`| `pve-mgmt-01` | Primary Proxmox Node. |
| `110`| `ct-mgmt-pbs-01` | Proxmox Backup Server. |
| `200`| `ct-srv-docker-01`| Internal Docker host (Minio + monitoring agents) -- **not Vaultwarden**, which has run as a k8s Deployment since the SEC-002/GIT-006 era; also **not Ansible-managed** at all currently, despite `app_nodes` existing in `inventory.ini` -- no play in `site.yml` targets it, a real IaC gap worth closing. |
| `301`| `ct-dmz-proxy-01` | External Nginx Proxy Manager (DMZ). |

The `rpi-srv-proxy-01` row previously here (an "Internal Nginx Proxy Manager" on RPi
hardware) has been removed -- `ansible/site.yml`'s `rpi_nodes` play explicitly *stops
and removes* an NPM Docker stack from RPi nodes as a `pre_tasks` cleanup step, meaning
that setup was migrated away at some point and this doc was never updated to match.
