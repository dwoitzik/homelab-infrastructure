terraform {
  required_version = ">= 1.5.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
  backend "s3" {
    bucket = "terraform-state"
    key    = "proxmox/terraform.tfstate"
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

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  # SEC-007: was `insecure = true`. Proxmox's self-signed cluster CA is now
  # trusted by the Atlantis runtime (ansible/roles/atlantis/files/Dockerfile),
  # so real TLS verification works instead of skipping it.
  insecure = false
}
