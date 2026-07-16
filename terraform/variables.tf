variable "server_name" {
  description = "Hostname of the AI workflow server"
  type        = string
  default     = "ai-server"
}

variable "server_type" {
  description = "Hetzner Cloud server type"
  type        = string
  default     = "cx33" # 4 shared AMD vCPU, 8 GB RAM, 80 GB SSD
}

variable "location" {
  description = "Hetzner Cloud location (fsn1, nbg1, hel1, ...)"
  type        = string
  default     = "nbg1"
}

variable "image" {
  description = "OS image"
  type        = string
  default     = "ubuntu-24.04"
}

variable "admin_user" {
  description = "Name of the non-root admin user created by cloud-init"
  type        = string
  default     = "admin"
}

variable "admin_ssh_public_key" {
  description = "Public half of the Ansible/admin bootstrap SSH key (the private half lives in Infisical at /ci/SSH_PRIVATE_KEY)"
  type        = string
  # REPLACE during bootstrap (step 5 in README):
  default = "ssh-ed25519 AAAA_REPLACE_ME ai-server-admin"
}

variable "bootstrap_admin_ip_cidr" {
  description = <<-EOT
    Single admin IP (CIDR) allowed to reach SSH during initial buildout.
    Set to null once Tailscale is up (Phase 3) to close all public inbound.
  EOT
  type        = string
  nullable    = true
  # REPLACE during bootstrap with e.g. "203.0.113.7/32"; Phase 3 sets null.
  default = null
}
