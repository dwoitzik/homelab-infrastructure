# ADR-084: Weekly Ansible drift check from the Proxmox host

**Date:** 2026-11-22
**Status:** Accepted, applied

## Context

Kubernetes drift is caught by ArgoCD self-heal and `drift-check.yml` (ADR-027), Terraform
drift by the PR-comment plan. Ansible had nothing: a merged role change only reaches a
host when someone runs the playbook. #1115 (Vaultwarden standby with
`SIGNUPS_ALLOWED=true`) was merged and never applied, and stayed live on rpi-srv-02 for
weeks until it was found by accident. `docs/ROADMAP.md` already listed a scheduled
Ansible drift report as open, blocked on "a control host that reaches every VLAN".

Only the admin VLAN (rule 03) can SSH into every VLAN, and nothing runs there
unattended. Candidates for the control host:

1. **The GitHub Actions runner (ct-srv-atlantis-01, SRV VLAN).** Already runs scheduled
   jobs, but needs SRV -> MGMT SSH (lower trust zone into the hypervisor) and would
   keep a root key for every host on a machine that executes workflow code.
2. **A Kubernetes CronJob.** Same SRV -> MGMT problem, plus an SSH key and the vault
   password as cluster Secrets.
3. **pve-mgmt-01 (MGMT VLAN).** Already root on every LXC and k3s VM it hosts. Needs
   MGMT -> SRV/DMZ SSH only, the direction trust already flows.

## Decision

Option 3. Role `ansible_drift_check` on `pve_hosts`:

- ansible-core 2.16.3 (the workstation's version) in a venv under `/opt/ansible-drift-check`, a clone of the public
  repo reset to `origin/main` on every run, the vault password and the ntfy topic in
  `/etc/ansible-drift-check` (0600).
- A dedicated ed25519 key, authorized on every inventory host with
  `from="10.0.10.10,10.0.20.1"`. The router masquerades MGMT -> SRV traffic to the SRV
  gateway (`srcnat_masquerade_mgmt_to_srv`), so SRV hosts see 10.0.20.1, which admin
  and home-network sessions share; on those hosts `from=` only keeps the key out of
  the DMZ and IoT VLANs.
- `ansible-drift-check.timer` (Sundays 06:30) runs `site.yml --check --diff` once per
  inventory host, then `rpi-ha-standby`, `litestream-standby`,
  `postgres-authelia-standby` (added once ADR-030 was first applied) and `tailscale`.
  Left out: the `k3s-cluster/` collection (k3s install and upgrade) and the
  localhost-only `vault-unseal-secret.yml`.
- Any host with `changed>0`, `failed>0` or `unreachable>0` goes into one ntfy message
  per run (the same topic as ADR-027), with the changed task names and the log path.
  A clean run sends nothing. When more than half the targets fail, the problem is the
  control side (network path, key), not the hosts: the run is marked failed, no ntfy
  is sent, and `AnsibleDriftCheckStale` reports it once through Alertmanager.
- Metrics in the node_exporter textfile directory; `AnsibleDriftCheckStale` fires when
  the check has not completed for 8 days, so a dead timer is not mistaken for silence.

Firewall rules `fwd_09h_pve_ansible_srv` and `fwd_09i_pve_ansible_dmz` (#1255) open
tcp/22 from 10.0.10.10 to the SRV and DMZ VLANs.

## Consequences

- Report only: nothing is applied automatically. Applying stays a deliberate
  run, because several roles restart DNS (AdGuard, keepalived) on the Pis.
- The vault password now also lives on the Proxmox host. Root there already reaches
  every guest's disk and memory, so this adds the two Raspberry Pis and the secrets
  that only exist in Ansible Vault.
- Any task that reports `changed` in check mode on an unchanged host becomes a weekly
  false alarm, so such tasks have to be made idempotent rather than tolerated.
- k3s nodes now set `ansible_user: dw` explicitly; it was implied by the workstation's
  SSH config and would have been `root` on the Proxmox host.
