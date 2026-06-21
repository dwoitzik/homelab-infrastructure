# Contributing

## Prerequisites

Install these tools locally before working on this repo:

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) >= 2.14
- [kubectl](https://kubernetes.io/docs/tasks/tools/) — for cluster operations
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

## Terraform Changes

All Terraform applies go exclusively through Atlantis (GitOps). Never run `terraform apply` locally.

1. Create a branch and make changes
2. Push and open a PR — Atlantis auto-posts `terraform plan` as a comment
3. Review the plan, then comment `atlantis apply` to apply
4. Merge after apply succeeds

```bash
git checkout -b feature/my-change
# edit terraform/stacks/network/*.tf or terraform/stacks/proxmox/*.tf
git push && gh pr create
```

## Ansible Changes

```bash
# Dry run first
ansible-playbook ansible/site.yml --check

# Apply to specific host group
ansible-playbook ansible/site.yml --limit rpi_nodes
```

Host groups: `rpi_nodes`, `app_nodes`, `mgmt_nodes`, `dmz_proxies`, `dmz_games`, `ai_nodes`.

## Adding a New Kubernetes Service

Services in `kubernetes/apps/` are auto-deployed by ArgoCD (ApplicationSet watches all subdirectories).

1. Create the app directory and manifest:

```bash
mkdir kubernetes/apps/my-service
# Create kubernetes/apps/my-service/my-service.yml with Deployment + Service [+ PVC]
```

2. Add an IngressRoute to `kubernetes/system/apps-ingressroute.yml`:

```yaml
---
# My Service
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myservice-final
  namespace: apps
spec:
  entryPoints: [websecure]
  routes:
  - match: Host(`myservice.woitzik.dev`)
    kind: Rule
    middlewares: [{name: authelia}]   # omit for services with their own auth
    services: [{name: my-service, port: 8080}]
  tls: {secretName: wildcard-woitzik-dev-tls}
```

3. Apply the IngressRoute manually (it's not ArgoCD-managed):

```bash
kubectl apply -f kubernetes/system/apps-ingressroute.yml
```

4. Commit and push — ArgoCD detects the new directory and deploys automatically.

If the service needs a Secret (passwords, tokens), keep a placeholder in git and apply the real value manually:

```bash
kubectl create secret generic my-service-secret -n apps \
  --from-literal=password=real-password \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Pre-commit Hooks

The following hooks run on every commit:

| Hook | What it checks |
|---|---|
| `trailing-whitespace` | No trailing spaces |
| `end-of-file-fixer` | Files end with newline |
| `check-yaml` | Valid YAML syntax |
| `tflint` | Terraform best practices |
| `yamllint` | YAML style |

Run manually:
```bash
pre-commit run --all-files
```

## Secrets

**Ansible:** All secrets live in `ansible/group_vars/all/vault.yml` (Ansible Vault encrypted). Variables use the `vault_` prefix by convention.

```bash
ansible-vault edit ansible/group_vars/all/vault.yml
```

**Kubernetes:** Secrets with real values are applied directly to the cluster, never committed to git. The git files contain `REPLACE_WITH_*` placeholders.

## CI

GitHub Actions runs on every push and PR to `main`:
- **Terraform**: `fmt -check`, `init -backend=false`, `validate`, `tflint` per stack
- **Ansible**: `ansible-lint` with full collection resolution

Both must pass before merging.
