# Vault Configuration Under Terraform — Staged Plan

**Date**: 2026-07-17
**Status**: Proposal only — each stage requires explicit authorization
**Prerequisite**: REL-065 (break-glass restore) proven working
**Context**: Vault is the trust root for every other secret. This plan
brings configuration (not secret values) under Terraform in a staged,
low-risk approach. Each stage is independently reversible.

---

## Current State

- **Vault**: Standalone mode, Raft storage, Helm chart v0.28.1
- **Location**: `kubernetes/system/vault/application.yml`
- **No Terraform stack exists** for Vault (`terraform/stacks/vault/` does not exist)
- **Config managed via**: `vault login` + `vault` CLI commands (manual)
- **Secrets in Vault**: KV v2 engine at `secret/`, paths for ~15+ apps
- **Secrets inventory**: `docs/secrets-inventory.md` documents every path
- **Break-glass restore**: REL-065 — proven working. Ansible Vault file
  (`ansible/group_vars/all/vault.yml`) is the durable source for secret values.
  Terraform manages configuration, never secret values.

## Scope

**In scope** (configuration):

- Vault policies (what can access what)
- Auth methods (Kubernetes auth, userpass, etc.)
- Secrets engines (KV v2 mount config, not secret values themselves)
- Roles and bindings for auth methods

**Out of scope** (stays manual / Ansible):

- Actual secret values (`secret/<app>/*` paths and their data)
- Unseal keys, root tokens
- Vault server config (Helm chart values, Raft config)
- TLS (currently disabled, out of scope)

## Provider Setup

New stack: `terraform/stacks/vault/`

```hcl
# providers.tf
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
  backend "s3" {
    bucket         = "terraform-state"
    key            = "vault/terraform.tfstate"
    region         = "homelab"
    endpoint       = "https://s3.woitzik.dev"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation       = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

provider "vault" {
  # Vault address — cluster-internal, no TLS
  address = "http://vault.vault.svc.cluster.local:8200"

  # Token sourced from environment (VAULT_TOKEN) or k8s Secret
  # Same pattern as Atlantis: token is an ESO-managed secret
  # injected as env var during TF plan/apply
}
```

**State backend**: Same S3 bucket as other stacks, separate key prefix.
This means Vault TF state lives in Garage — same circularity as other
stacks, but acceptable because this state describes *configuration*, not
*secrets*. Losing the state means re-importing config, not leaking secrets.

---

## Stage 1: Policies (lowest risk, no Vault impact)

**What**: Import existing Vault policies into Terraform. Policies are
purely declarative — they describe access rules but don't change anything
about Vault's operation.

**What gets terraformed first**:

```hcl
# policies.tf — example structure
resource "vault_policy" "eso" {
  name   = "eso"
  policy = file("${path.module}/policies/eso.hcl")
}

resource "vault_policy" "renovate" {
  name   = "renovate"
  policy = file("${path.module}/policies/renovate.hcl")
}

# ... one per policy in the cluster
```

**HCL policy files**: One `.hcl` file per policy under `policies/`.
These are already documented in `docs/secrets-inventory.md` — extract
the existing rules into files.

**Verification before proceeding**:

1. `terraform plan` shows only `import` blocks matching live state
2. `terraform apply` imports all policies — zero changes to Vault
3. `vault policy list` unchanged (same policies, same names)
4. `vault policy read <name>` output matches the HCL file for 2-3 policies

**Rollback**: `terraform state rm vault_policy.<name>` for each, then
delete the HCL files. Vault policies are stateless — removing from TF
doesn't delete them from Vault.

**Vault unavailable?** No. Policies are read-only from Vault's perspective.
No restart, no unseal, no client disruption.

---

## Stage 2: KV v2 Secrets Engine Mount Config

**What**: Import the `secret/` KV v2 mount configuration into Terraform.
This configures the engine's existence and settings (version, max versions,
delete version after) but NOT the secret values.

```hcl
# secrets-engines.tf
resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "KV v2 secrets engine — application secrets"
}
```

**Risk**: If the mount already exists at `secret/` with the same config,
`terraform plan` should show no changes (just an import). If the
configuration differs (e.g., `max_versions` was set differently), the
plan would show a diff — review carefully before applying.

**Verification**:

1. `terraform plan` shows import-only or no-op for the mount
2. `vault read sys/mounts/secret/` output matches the HCL config
3. `vault kv list secret/` still works — no disruption to existing secrets

**Rollback**: `terraform state rm vault_mount.secret`. Mount stays in
Vault unchanged.

**Vault unavailable?** No. Mount config import is read-only.

---

## Stage 3: Kubernetes Auth Method (medium risk — needs token)

**What**: Import the Kubernetes auth method configuration. This is where
Vault trusts the k8s API server to authenticate pods.

```hcl
# auth.tf
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "config" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = "https://kubernetes.default.svc"
  # Token review CA — needed for token validation
  kubernetes_ca_cert = file("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
}
```

**Risk**: If the auth method is already configured, import + apply should
be a no-op. If there's a config drift (e.g., the `kubernetes_host` or
CA cert differs), the plan shows a diff. **Do not apply a diff here
blindly** — auth method misconfiguration breaks every ESO sync.

**Verification**:

1. `terraform plan` shows import-only or no-op
2. `vault read sys/auth/kubernetes` output matches the HCL
3. Trigger one ESO sync (`kubectl annotate externalsecret -n <ns> <name> force-sync=$(date)`) —
   confirm it still succeeds
4. Check 3-5 apps that depend on Vault secrets — no restarts, no errors

**Rollback**: `terraform state rm vault_auth_backend.kubernetes
vault_kubernetes_auth_backend_config.config`. Auth method stays in Vault
unchanged.

**Vault unavailable?** No. This is configuration import, not reconfiguration.
However, if the apply *changes* the config (not just imports), there could
be a brief window where Vault re-validates the auth backend — typically
<1s, no client-visible disruption.

---

## Stage 4: Kubernetes Auth Roles (medium risk)

**What**: Import the roles that map Kubernetes ServiceAccounts to Vault
policies. This is the binding between "which pod" and "what it can access."

```hcl
# auth-roles.tf
resource "vault_kubernetes_auth_backend_role" "eso" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "eso"
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = ["eso"]
  token_ttl                        = 3600
}

# ... one role per app/service account
```

**Risk**: If roles already exist, import is safe. If you're adding NEW roles
(not just importing existing ones), this changes what pods can access.
Review each role's `bound_service_account_names` + `token_policies` against
the live config.

**Verification**:

1. `terraform plan` shows import-only or no-op for existing roles
2. For any NEW roles: verify the role doesn't grant access beyond what
   the app needs (least-privilege check)
3. Trigger ESO syncs for affected apps — confirm success
4. `vault read auth/kubernetes/role/<name>` matches the HCL

**Rollback**: `terraform state rm vault_kubernetes_auth_backend_role.<name>`.
Role stays in Vault unchanged.

**Vault unavailable?** No.

---

## Stage 5: Additional Auth Methods (if any) — deferred

**What**: Userpass, OIDC, or other auth methods beyond Kubernetes.
Currently only Kubernetes auth is in use (all Vault access goes through
ESO). If no other auth methods exist, skip this stage entirely.

**Verification**: Same pattern — import, diff, verify, no-op.

---

## Stage 6: App Policies (lowest risk addition — pure additive)

**What**: Import the per-app policies (one per ESO-managed secret path).
These are the most granular — each policy controls exactly which
secret path an app's role can read.

```hcl
# per-app-policy.tf — one resource per app
resource "vault_policy" "authelia" {
  name   = "authelia"
  policy = file("${path.module}/policies/authelia.hcl")
}
```

**Risk**: Lowest — policies are additive, don't affect existing access
until a role references them. Importing existing policies is safe.

**Verification**:

1. `terraform plan` shows import-only for each policy
2. Spot-check 3-5 policies: `vault policy read <name>` matches the HCL file
3. No app disruption (policies don't change, just their TF representation)

**Rollback**: `terraform state rm vault_policy.<name>`.

**Vault unavailable?** No.

---

## What Stays Manual Longest

| Item | Why | When to revisit |
|---|---|---|
| **Secret values** (`secret/<app>/*`) | Never in Terraform — Ansible Vault is the durable source. ESO syncs from Vault to k8s Secrets. | Never — this is the correct pattern |
| **Vault server config** (Helm values, Raft) | Managed by ArgoCD + Helm, not Terraform. Changing this via TF would fight ArgoCD. | When/if Vault moves to a non-ArgoCD-managed install |
| **Unseal keys / root tokens** | Security-sensitive, manual by design. The vault-unseal Deployment handles unsealing automatically. | Never |
| **TLS config** | Currently disabled. When enabled, cert management is a separate concern (cert-manager, not Vault TF). | When TLS is enabled |
| **Vault upgrades** (Helm chart version) | Renovate handles this via PR, not Terraform. Renovate's `stateful/critical` rule gates these to manual merge. | Ongoing via Renovate |

---

## Maintenance Window Plan

Each stage can be done in the same window as etcd/DNS work, but
independently. Recommended order within the window:

1. **Stage 1** (policies) — 15 min, zero impact, good warm-up
2. **Stage 2** (KV mount) — 5 min, zero impact
3. **Stage 3** (k8s auth) — 10 min, zero impact if import-only
4. **Stage 4** (auth roles) — 15 min, zero impact if import-only
5. **Stage 6** (app policies) — 20 min, zero impact

Total: ~1 hour. All stages are independently reversible.
No Vault downtime required for any stage.

**If any stage shows unexpected drift** (terraform plan shows changes,
not just imports): STOP, investigate, do not apply. The diff tells you
exactly what's different. Fix in git or in Vault manually, re-plan.

---

## File Structure

```text
terraform/stacks/vault/
├── providers.tf           # Vault provider + S3 backend
├── main.tf                # Mount config, auth backend
├── policies.tf            # All vault_policy resources
├── auth.tf                # Kubernetes auth backend + config
├── auth-roles.tf          # All vault_kubernetes_auth_backend_role resources
├── policies/
│   ├── eso.hcl
│   ├── renovate.hcl
│   ├── authelia.hcl
│   ├── velero.hcl
│   └── ... (one per policy)
└── variables.tf           # Any TF vars (if needed)
```

Each policy `.hcl` file is extracted from the live Vault instance
(`vault policy read <name>`) and committed to git. This is the single
source of truth for policy configuration.
