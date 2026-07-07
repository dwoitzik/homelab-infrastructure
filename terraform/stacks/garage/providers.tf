terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

  endpoints {
    s3 = "https://s3.woitzik.dev"
  }
}
