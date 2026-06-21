# Terraform

Everything here applies through Atlantis. I don't run `terraform apply` from my own machine.

## Structure

```
terraform/stacks/
├── network/      # MikroTik — VLANs, firewall, DHCP, NAT, IPv6
└── proxmox/      # VMs and LXCs
```

### `stacks/network`

Manages the MikroTik via the [terraform-routeros provider](https://github.com/terraform-routeros/terraform-routeros):

- Firewall filter rules, IPv4 and IPv6 (`firewall_deterministic.tf`, `firewall_extra.tf`, `firewall_ipv6.tf`)
- NAT and port forwards (`nat_portforward.tf`)
- VLANs, bridge config, DHCP (`main.tf`, `dhcp.tf`)
- SNMP, WAN/IPv6 setup, scheduled power tasks (`snmp.tf`, `wan.tf`, `ipv6_network.tf`, `power.tf`)
- `imports.tf` — pre-existing RouterOS objects (services, firewall rules) adopted into Terraform via native `import` blocks rather than recreated

### `stacks/proxmox`

VMs and LXCs via the [bpg/proxmox provider](https://github.com/bpg/terraform-provider-proxmox).

## Making a change

```bash
git checkout -b feature/my-change
# edit terraform/stacks/<stack>/*.tf
git push && gh pr create
# Atlantis posts the plan as a PR comment
# comment "atlantis apply" once it looks right
```

## Variables

Each stack needs its own `terraform.tfvars` (not committed — copy from `terraform.tfvars.example`).

## State

Both stacks use a Garage S3 backend (self-hosted, in-cluster — see `docs/decisions/ADR-003-garage-terraform-backend.md`). Not stored in this repo.

## Adding a stack

```bash
mkdir -p terraform/stacks/my_stack
# main.tf, variables.tf, providers.tf
# add to atlantis.yaml
# add to .github/workflows/ci.yml
```
