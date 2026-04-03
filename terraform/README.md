# Terraform

Infrastructure provisioning managed as code. All changes are applied exclusively through pull requests via **Atlantis** — no direct `terraform apply` from local machines in normal operation.

## Structure

```
terraform/
└── stacks/
    └── network/              # Active — MikroTik firewall, VLANs, NAT, DNS
        ├── main.tf           # Provider configuration
        ├── firewall.tf       # Input/forward chains, NAT rules
        ├── vpn.tf            # WireGuard configuration
        ├── variables.tf      # Input variable declarations
        └── locals.tf         # Local values
```

## Active Stacks

### `stacks/network`
Manages all MikroTik RouterOS configuration via the [terraform-routeros provider](https://github.com/terraform-routeros/terraform-routeros):

- Firewall filter rules (input + forward chains, zero-trust policy)
- NAT rules (hairpin NAT, port forwarding)
- VLAN definitions (Mgmt, DMZ, Server, IoT, Admin)
- WireGuard VPN peers
- Cloudflare DNS records

## Making Changes

```bash
# Never apply directly — open a PR instead
git checkout -b feature/firewall-rule
# edit terraform/stacks/network/*.tf
git push origin feature/firewall-rule
# open PR → Atlantis posts plan as PR comment
# review plan → comment "atlantis apply" to apply
```

For emergency local apply only:
```bash
cd terraform/stacks/network
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

## Required Variables

Copy and fill in `terraform.tfvars` (never commit this file):

```hcl
mikrotik_url      = "https://10.0.10.1"
mikrotik_user     = "terraform"
mikrotik_password = ""
mikrotik_insecure = true
```

## State

Terraform state is managed locally by Atlantis in `/home/atlantis/.atlantis/` on the Docker LXC. State is not stored in this repository.

## Adding a New Stack

```bash
mkdir -p terraform/stacks/my_stack
# create main.tf, variables.tf
# add to atlantis.yaml projects list
# add to .github/workflows/ci.yml terraform job
```
