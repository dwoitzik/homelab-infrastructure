variable "mikrotik_url" {
  type        = string
  description = "The REST API URL of the MikroTik device (e.g., https://10.0.10.1)"
}

variable "mikrotik_user" {
  type        = string
  description = "The username for the Terraform API user"
}

variable "mikrotik_password" {
  type        = string
  sensitive   = true
  description = "The password for the Terraform API user"
}

variable "mikrotik_insecure" {
  type        = bool
  default     = true
  description = "Whether to allow insecure (self-signed) SSL certificates"
}
