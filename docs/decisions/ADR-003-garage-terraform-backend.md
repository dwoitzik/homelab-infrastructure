# ADR-003: Garage as self-hosted Terraform state backend

**Date:** 2026-04 (Original), 2026-05 (Updated)
**Status:** Accepted

## Context

Terraform requires a state backend to store the current state of managed infrastructure. We migrated from Minio to Garage for better integration with the K3s cluster.

The primary requirements remain:

- State must be accessible from Atlantis running in Kubernetes
- State must be accessible from developer machines for emergency local runs
- No external SaaS dependency
- State locking to prevent concurrent applies

## Decision

Deploy Garage in the `apps` namespace as an S3-compatible object storage backend. Configure the Terraform S3 backend provider to point at the internal Garage service.

```hcl
backend "s3" {
  bucket = "terraform-state"
  key    = "network/terraform.tfstate"
  region = "homelab"
  endpoints = {
    s3 = "http://garage.apps.svc.cluster.local:3900"
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

**S3-compatible API:** Garage implements the S3 API and handles global aliases and keys efficiently.
**Kubernetes Native:** Running Garage inside the cluster provides better service discovery and lifecycle management via ArgoCD.
**State locking:** Standard S3 object locking is supported.

## Consequences

Buckets are managed via the `garage` CLI. The `terraform-state` bucket stores state for all stacks.
Note: If state becomes corrupted or lost during migration, resources must be re-imported into a fresh bucket using `atlantis import` commands defined in `TERRAFORM_IMPORT.md`.
