# ADR-003: Minio as self-hosted Terraform state backend

**Date:** 2026-04
**Status:** Accepted

## Context

Terraform requires a state backend to store the current state of managed infrastructure. The options considered were:

- Local state file on the developer's machine
- Terraform Cloud (HashiCorp SaaS)
- S3 (AWS)
- Self-hosted S3-compatible object storage (Minio)

The primary requirements were:

- State must be accessible from Atlantis running on the Docker LXC
- State must be accessible from developer machines for emergency local runs
- No external SaaS dependency for a core infrastructure component
- State locking to prevent concurrent applies

## Decision

Deploy Minio on the Docker LXC (`ct-srv-docker-01`, `10.0.20.252:9000`) as an S3-compatible object storage backend for all Terraform stacks. Configure the Terraform S3 backend provider to point at the internal Minio endpoint.

```hcl
backend "s3" {
  bucket   = "terraform-state"
  key      = "network/terraform.tfstate"
  region   = "main"
  endpoints = {
    s3 = "http://10.0.20.252:9000"
  }
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  skip_s3_checksum            = true
  use_path_style              = true
}
```

## Reasons

**No external dependency:** Terraform Cloud or AWS S3 would introduce an external SaaS dependency for state — if the external service is unavailable, no infrastructure changes can be applied. Minio runs internally and is available as long as the homelab is running.

**S3-compatible API:** Minio implements the full S3 API, meaning the standard Terraform S3 backend works without any custom provider or plugin. The same backend configuration pattern used in production AWS environments applies here.

**State locking:** Minio supports S3 object locking, preventing concurrent `terraform apply` runs from corrupting state — relevant when both Atlantis and a developer machine might attempt applies.

**Fits existing architecture:** Minio runs as a Docker container managed by Ansible on the same LXC as Atlantis, maintaining a consistent operational model with the rest of the stack.

**Cost:** Free and self-contained — no per-request or per-GB charges.

## Trade-offs

- Minio itself has no redundancy — if the Docker LXC fails, state is temporarily inaccessible (though not lost, as PBS backs up the LXC daily)
- Requires Minio to be running before any `terraform init` — a chicken-and-egg problem on a fresh rebuild (mitigated by the disaster recovery protocol: restore PBS → restore LXC → Terraform state is recovered)
- Credentials must be managed separately (stored in Ansible Vault and injected via Atlantis environment variables)

## Consequences

Each new Terraform stack gets its own key path in the `terraform-state` bucket (e.g. `network/terraform.tfstate`, `proxmox/terraform.tfstate`). Minio is managed via the existing Ansible `minio` role and backed up as part of the standard PBS daily backup cycle.
