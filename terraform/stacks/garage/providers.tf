terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket = "terraform-state"
    key    = "garage/terraform.tfstate"
    region = "homelab"
    endpoints = {
      s3 = "https://s3.woitzik.dev"
    }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

# Garage's S3-compatible API for bucket lifecycle (create/list/delete). Reuses
# the same AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY env vars Atlantis already
# has set globally for the Terraform state backend (the "atlantis" Garage
# key) -- granted RWO access to loki-data/velero/cnpg-backups live before
# this stack was written (docs/IAC-GAPS.md item 3), same identity, no new
# credential to manage.
provider "aws" {
  region                      = "homelab"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  # Without this, the provider defaults to virtual-hosted-style addressing
  # (e.g. https://velero.s3.woitzik.dev/) instead of path-style
  # (https://s3.woitzik.dev/velero) -- those per-bucket subdomains don't
  # resolve to anything routable, which hung every HeadBucket call for
  # ~25 retries with backoff instead of failing fast. Confirmed live via
  # TF_LOG=DEBUG: this was the actual cause of a stuck Atlantis plan lock.
  # The backend "s3" block above already had the equivalent (use_path_style)
  # set correctly; this is the same setting for the resource-managing
  # provider, which is configured separately.
  s3_use_path_style = true

  endpoints {
    s3 = "https://s3.woitzik.dev"
  }
}
