terraform {
  required_version = ">= 1.5.0"

  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.99.1"
    }
  }

  backend "s3" {
    bucket                      = "terraform-state"
    key                         = "network/terraform.tfstate"
    region                      = "main"

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
}

provider "routeros" {
  hosturl  = var.mikrotik_url
  username = var.mikrotik_user
  password = var.mikrotik_password
  insecure = var.mikrotik_insecure
}
