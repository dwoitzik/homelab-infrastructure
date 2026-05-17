# 🛠️ My Ansible Configuration

I use Ansible to manage the base OS and core services that aren't (yet) in the K3s cluster.

## 🏗️ Deployment Status

I've started migrating my primary applications to K3s. To avoid conflicts, I've commented out the following roles in `site.yml`:
- `authelia`: Now running as a high-availability deployment in K3s.
- `paperless`: Migrated to gain distributed storage via Longhorn.
- `minio`: Moved to the cluster for better resource management.
- `vaultwarden`: My password manager is now cluster-native.
- `open_webui`: Migrated to the cluster.

## 🍓 Raspberry Pi Edge Cluster
The RPis still run natively for now to handle core network services:
- **Keepalived**: High-availability VIP for DNS.
- **AdGuard Home**: DNS filtering and blocking.
- **Unbound**: Recursive DNS resolution.
- **HAProxy**: Load balancing for the Edge.

## 🚀 How I Run It

```bash
# I run this when I want to update the base nodes
ansible-playbook playbooks/site.yml --vault-password-file .ansible_vault_pass
```

## 🔐 Secrets Management
I store all my credentials in `group_vars/all/vault.yml`. I use Ansible Vault to keep them encrypted.
