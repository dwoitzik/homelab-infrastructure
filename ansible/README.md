# Ansible

Manages the base OS and services that run outside the k3s cluster.

## What Ansible manages

| Host group | Hosts | Roles |
|---|---|---|
| `rpi_nodes` | rpi-srv-01 (10.0.20.2), rpi-srv-02 (10.0.20.3) | common, docker, watchtower, monitoring_agent, rpi_optimize, keepalived, adguard, unbound, haproxy |
| `app_nodes` | ct-srv-docker-01 (10.0.20.252) | common, docker, watchtower, monitoring_agent |
| `dmz_proxies` | ct-dmz-proxy-01 (10.0.30.2) | common, docker, watchtower, monitoring_agent, nginx_proxy_manager, crowdsec_bouncer |
| `dmz_games` | ct-dmz-games-01 (10.0.30.3) | common, docker, watchtower, monitoring_agent, minecraft |
| `mgmt_nodes` | ct-mgmt-pbs-01 (10.0.10.110) | node_exporter_native, pbs |
| `ai_nodes` | ct-srv-ai-01 (10.0.20.251) | node_exporter_native, ollama |
| `k3s_nodes` | vm-srv-k3s-11/12/13 (10.0.20.11-13) | Not in `site.yml` — used only by the standalone `k3s-vip.yml` playbook (Keepalived HA VIP). k3s itself is provisioned separately, see "k3s provisioning" below. |

Services that previously ran via Ansible (authelia, vaultwarden, paperless, open_webui, minio, monitoring) have been migrated to k3s and are now managed by ArgoCD.

## Running playbooks

```bash
# Dry run (check mode)
ansible-playbook playbooks/site.yml --check

# Apply to all hosts
ansible-playbook playbooks/site.yml

# Apply to a single group
ansible-playbook playbooks/site.yml --limit rpi_nodes

# Apply to a single host
ansible-playbook playbooks/site.yml --limit rpi-srv-01
```

The vault password file must exist at `ansible/.ansible_vault_pass` before running.

## Secrets

All secrets are encrypted in `group_vars/all/vault.yml` with Ansible Vault.

```bash
ansible-vault edit group_vars/all/vault.yml
```

## k3s provisioning

`ansible/k3s-cluster/` contains the k3s installation playbook (based on k3s-ansible).
Use this to provision a fresh cluster or upgrade existing nodes.

```bash
cd ansible/k3s-cluster
ansible-playbook playbooks/site.yml -i inventory.yml
```

**Stale as of 2026-08-16 — corrected**: the cluster is single-server (`vm-srv-k3s-11`
only), not HA, and its datastore is SQLite via kine, not etcd — see
`docs/decisions/ADR-015-k3s-datastore-sqlite.md` and `docs/k3s-architecture.md` for the
full picture and why. `inventory-ha.yml` in that directory documents a 3-server/embedded-etcd
target that was tried, reverted (repeated host freezes — 3 VMs sharing one physical host/
storage pool couldn't sustain 3 concurrent etcd writers), and is **not** the current or
intended target. Do not use it for a real rebuild.

## Standalone playbooks (top-level `ansible/*.yml`)

These aren't part of `site.yml` — run them individually when needed:

| Playbook | Purpose |
|---|---|
| `k3s-vip.yml` | Deploys Keepalived VIP `10.0.20.10` for k3s API HA across all 3 server nodes |
| `vault-unseal-secret.yml` | (Re-)creates the `vault-unseal-keys` k8s Secret from the Ansible Vault unseal keys — run after key rotation |
| `tailscale.yml` | Connects RPi nodes to Headscale + sets up the MetalLB DNAT workaround |
