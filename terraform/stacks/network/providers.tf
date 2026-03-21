terraform {
  required_version = ">= 1.5.0"
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.76.3"
    }
  }
}

provider "routeros" {
  hosturl  = var.mikrotik_url
  username = var.mikrotik_user
  password = var.mikrotik_password
  insecure = true
}
