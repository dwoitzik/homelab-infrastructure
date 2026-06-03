bucket = "terraform-state"
key    = "network/terraform.tfstate"
region = "homelab"
endpoints = {
  s3 = "http://localhost:3900"
}
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_requesting_account_id  = true
skip_s3_checksum            = true
use_path_style              = true
access_key                  = "GKf5de79528ade5ffced70bd20"
secret_key                  = "1b5bd8fa6bbe0a9a8f360368256b8be9800fcc8b297425caad89c828bf4731a4"
