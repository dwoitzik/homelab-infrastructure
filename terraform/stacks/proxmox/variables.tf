variable "proxmox_api_url" {
  type        = string
  description = "Proxmox API URL (e.g. https://10.0.10.10:8006/api2/json)"
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API token ID (e.g. terraform@pve!atlantis)"
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "Proxmox API token secret UUID"
  sensitive   = true
}
