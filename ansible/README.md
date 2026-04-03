# Ansible

Configuration management for all homelab nodes. Roles are designed to be idempotent — safe to run repeatedly without side effects.

## Structure

```
ansible/
├── roles/                    # One role per service
│   ├── common/               # Base OS config, packages, timezone
│   ├── docker/               # Docker engine + compose plugin
│   ├── watchtower/           # Automatic container updates
│   ├── monitoring_agent/     # node_exporter (all nodes)
│   ├── monitoring_core/      # Prometheus + Grafana + SNMP exporter
│   ├── keepalived/           # VIP failover (RPi nodes)
│   ├── adguard/              # AdGuard Home + adguardhome-sync
│   ├── unbound/              # Recursive DNS resolver
│   ├── nginx_proxy_manager/  # Reverse proxy + SSL termination
│   ├── rpi_optimize/         # zram, log2ram (RPi nodes)
│   ├── vaultwarden/          # Self-hosted password manager
│   ├── mikrodash/            # MikroTik dashboard
│   ├── atlantis/             # GitOps Terraform runner
│   ├── cloudflared/          # Cloudflare Tunnel (zero inbound ports)
│   ├── crowdsec_bouncer/     # Firewall bouncer (DMZ nodes)
│   └── minecraft/            # Game server (DMZ)
├── playbooks/
│   └── site.yml              # Main playbook — all hosts
├── group_vars/
│   ├── all/
│   │   ├── common.yml        # Shared variables
│   │   └── vault.yml         # Encrypted secrets (ansible-vault)
│   └── ...
├── inventory.ini             # Host inventory
├── ansible.cfg               # Ansible configuration
└── requirements.yml          # Collection dependencies
```

## Host Groups

| Group | Hosts | Roles applied |
|---|---|---|
| `nodes` | all | common, docker, watchtower, monitoring_agent |
| `rpi_nodes` | rpi-srv-01, rpi-srv-02 | rpi_optimize, keepalived, adguard, unbound, nginx_proxy_manager |
| `app_nodes` | ct-srv-docker-01 | vaultwarden, mikrodash, monitoring_core, atlantis, cloudflared |
| `dmz_proxies` | ct-dmz-proxy-01 | nginx_proxy_manager, crowdsec_bouncer |
| `dmz_games` | ct-dmz-games-01 | minecraft |

## Running Playbooks

```bash
# Full deployment (dry run)
ansible-playbook playbooks/site.yml --check --vault-password-file .ansible_vault_pass

# Full deployment
ansible-playbook playbooks/site.yml --vault-password-file .ansible_vault_pass

# Specific host group
ansible-playbook playbooks/site.yml --limit app_nodes --vault-password-file .ansible_vault_pass

# Single role (using tags)
ansible-playbook playbooks/site.yml --tags monitoring_core --vault-password-file .ansible_vault_pass
```

## Secrets

All secrets are stored in `group_vars/all/vault.yml`, encrypted with Ansible Vault. The vault password file is `.ansible_vault_pass` (not committed — gitignored).

```bash
# Edit secrets
ansible-vault edit group_vars/all/vault.yml

# Re-encrypt with new password
ansible-vault rekey group_vars/all/vault.yml
```

## Adding a New Role

```bash
# Create role structure
ansible-galaxy init roles/my_service

# Add to site.yml under the appropriate host group
# Add any secrets to group_vars/all/vault.yml
# Add collection dependencies to requirements.yml if needed
```
