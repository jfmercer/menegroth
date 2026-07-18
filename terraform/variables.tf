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

# The server boots from the FDE snapshot produced by the Packer pipeline
# (packer/README.md) — build one BEFORE the first apply of this config.
variable "fde_image_selector" {
  description = "Label selector matching the Packer-built FDE snapshot"
  type        = string
  default     = "fde=true,role=ai-server-base"
}

variable "admin_user" {
  description = "Name of the non-root admin user created by cloud-init"
  type        = string
  default     = "admin"
}

variable "admin_ssh_public_key" {
  description = "Public half of the Ansible/admin bootstrap SSH key (private half in Infisical /ci/SSH_PRIVATE_KEY). No default: injected in CI as TF_VAR_admin_ssh_public_key from Infisical /ci/ADMIN_SSH_PUBLIC_KEY — set it in your environment for local plans."
  type        = string
  # No default: Infisical is the single source of truth (scripts/bootstrap).

  # Fail fast on a malformed key instead of letting Hetzner reject it at apply.
  validation {
    condition     = can(regex("^ssh-", var.admin_ssh_public_key))
    error_message = "The admin_ssh_public_key must be an OpenSSH public key (starts with 'ssh-'); in CI it comes from Infisical /ci/ADMIN_SSH_PUBLIC_KEY."
  }
}

variable "data_volume_size" {
  description = "Size of the encrypted data volume in GB (growable later; shrinking requires recreate+restore)"
  type        = number
  default     = 20
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
