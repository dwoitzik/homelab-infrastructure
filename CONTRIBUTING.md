# Contributing

## Prerequisites

Install these tools locally before working on this repo:

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) >= 2.14
- [pre-commit](https://pre-commit.com/#install)
- [tflint](https://github.com/terraform-linters/tflint#installation)
- [ansible-lint](https://ansible.readthedocs.io/projects/lint/installing/)

## Setup

```bash
git clone https://github.com/dwoitzik/homelab-infrastructure
cd homelab-infrastructure

# Install pre-commit hooks
pre-commit install

# Install Ansible collections
ansible-galaxy collection install -r ansible/requirements.yml
```

## Workflow

All infrastructure changes follow the same flow regardless of whether it's Terraform or Ansible:

1. Create a branch: `git checkout -b feature/my-change`
2. Make changes
3. Pre-commit hooks run automatically on `git commit` — fix any issues
4. Push and open a PR
5. CI runs automatically (Terraform lint + validate, Ansible lint)
6. For Terraform changes: Atlantis posts a `terraform plan` as a PR comment
7. Review the plan, then comment `atlantis apply` to apply
8. Merge after apply succeeds

## Pre-commit Hooks

The following hooks run on every commit:

| Hook | What it checks |
|---|---|
| `trailing-whitespace` | No trailing spaces |
| `end-of-file-fixer` | Files end with newline |
| `check-yaml` | Valid YAML syntax |
| `tflint` | Terraform best practices |
| `yamllint` | YAML style |

Run manually at any time:
```bash
pre-commit run --all-files
```

## Secrets

Never commit secrets. All secrets live in `ansible/group_vars/all/vault.yml` (Ansible Vault encrypted) or are injected as environment variables via Atlantis.

If you need to add a new secret:

```bash
ansible-vault edit ansible/group_vars/all/vault.yml
# add your variable with vault_ prefix convention
# reference it in the relevant role defaults or vars
```

## Adding a New Service

### Via Ansible (Docker container on app_nodes):

```bash
# Create role
ansible-galaxy init ansible/roles/my_service

# Add to site.yml under appropriate host group
# Add Docker Compose template to roles/my_service/templates/
# Add secrets to vault if needed
# Test with --check first
ansible-playbook ansible/playbooks/site.yml --limit app_nodes --check
```

### Via Terraform (new infrastructure resource):

```bash
# Add .tf file to existing stack or create new stack
# Add to atlantis.yaml if new stack
# Open PR — Atlantis handles the rest
```

## CI

GitHub Actions runs on every push and PR:

- **Terraform**: `fmt`, `validate`, `tflint`, plan on PR
- **Ansible**: `ansible-lint` with full collection resolution

A green CI badge is required before merging to main.
