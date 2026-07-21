packer {
  required_plugins {
    hcloud = {
      source  = "github.com/hetznercloud/hcloud"
      version = "~> 1.6"
    }
  }
}

# Credentials/secrets arrive via environment only (CI pulls them from
# Infisical): HCLOUD_TOKEN, PKR_VAR_root_luks_passphrase,
# PKR_VAR_boot_tailscale_authkey.
variable "root_luks_passphrase" {
  type      = string
  sensitive = true
  # The same passphrase the Mac unlock agent reads from 1Password; recovery
  # copy lives in Infisical /unlock/ROOT_LUKS_KEY.
}

variable "boot_tailscale_authkey" {
  type      = string
  sensitive = true
  # Reusable, pre-authorized, EPHEMERAL auth key restricted to
  # tag:boot-unlock. Stored in Infisical /unlock/TS_BOOT_AUTHKEY. It lives in
  # plaintext on /boot — see docs/architecture.md D2 for the threat model.
}

variable "mac_unlock_ssh_pubkey" {
  type = string
  # Public half of the Mac unlock agent's SSH key (macos/README.md). No default:
  # provided in CI as PKR_VAR_mac_unlock_ssh_pubkey from Infisical
  # /unlock/MAC_UNLOCK_SSH_PUBKEY. The validate job passes a placeholder -var;
  # a real build with a malformed key fails here instead of baking an image
  # whose remote unlock can never work.
  validation {
    condition     = can(regex("^ssh-", var.mac_unlock_ssh_pubkey))
    error_message = "The mac_unlock_ssh_pubkey must be an OpenSSH public key (starts with 'ssh-'); in CI it comes from Infisical /unlock/MAC_UNLOCK_SSH_PUBKEY."
  }
}

variable "ubuntu_series" {
  type    = string
  default = "resolute" # 26.04 — must match the fleet
}

variable "tailscale_version" {
  type    = string
  default = "1.94.2" # static build embedded in the initramfs; bump via PR
}

variable "boot_hostname" {
  type    = string
  default = "menegroth-server-boot" # the initramfs tailnet node name
}

source "hcloud" "fde" {
  server_name = "packer-fde-build"
  # Same type as production so the snapshot's disk geometry matches exactly.
  server_type   = "cx33"
  location      = "nbg1"
  image         = "ubuntu-26.04" # only hosts the rescue boot; overwritten below
  rescue        = "linux64"      # build happens from the rescue system
  ssh_username  = "root"
  snapshot_name = "fde-ubuntu-26.04-{{timestamp}}"
  snapshot_labels = {
    fde  = "true"
    os   = "ubuntu-26.04"
    role = "menegroth-server-base"
  }
}

build {
  sources = ["source.hcloud.fde"]

  provisioner "file" {
    source      = "${path.root}/files"
    destination = "/tmp/fde-files"
  }

  provisioner "shell" {
    script = "${path.root}/scripts/install-fde.sh"
    environment_vars = [
      "LUKS_PASSPHRASE=${var.root_luks_passphrase}",
      "TS_BOOT_AUTHKEY=${var.boot_tailscale_authkey}",
      "MAC_UNLOCK_PUBKEY=${var.mac_unlock_ssh_pubkey}",
      "UBUNTU_SERIES=${var.ubuntu_series}",
      "TAILSCALE_VERSION=${var.tailscale_version}",
      "BOOT_HOSTNAME=${var.boot_hostname}",
    ]
  }
}
