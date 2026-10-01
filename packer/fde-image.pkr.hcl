packer {
  required_plugins {
    hcloud = {
      source  = "github.com/hetznercloud/hcloud"
      version = "~> 1.7"
    }
  }
}

# Credentials/secrets arrive via environment only (CI pulls them from
# Infisical): HCLOUD_TOKEN, PKR_VAR_root_luks_passphrase,
# PKR_VAR_boot_tailscale_oauth_secret, PKR_VAR_server_tailscale_oauth_secret.
variable "root_luks_passphrase" {
  type      = string
  sensitive = true
  # The same passphrase the Mac unlock agent reads from 1Password; recovery
  # copy lives in Infisical /unlock/ROOT_LUKS_KEY.
}

# Both tailnet credentials are Tailscale OAuth client secrets, not auth keys:
# auth keys expire after at most 90 days, which would silently break the
# boot unlock and fresh-server joins (docs/architecture.md D10). Each client
# is restricted to ONE tag with the auth_keys scope; `tailscale up` mints a
# short-lived key from it at join time.
variable "boot_tailscale_oauth_secret" {
  type      = string
  sensitive = true
  # tag:boot-unlock client. Stored in Infisical /unlock/TS_BOOT_OAUTH_SECRET.
  # It lives in plaintext in the initramfs on /boot — see D2/D10.
  validation {
    condition     = can(regex("^tskey-client-", var.boot_tailscale_oauth_secret))
    error_message = "The boot_tailscale_oauth_secret must be a Tailscale OAuth client secret (tskey-client-...), not an expiring auth key."
  }
}

variable "server_tailscale_oauth_secret" {
  type      = string
  sensitive = true
  # tag:server client. Stored in Infisical /ci/TS_SERVER_OAUTH_SECRET. Baked
  # onto the ENCRYPTED root for the first-boot tailnet join, then deleted
  # by tailscale-firstboot once the node has joined.
  validation {
    condition     = can(regex("^tskey-client-", var.server_tailscale_oauth_secret))
    error_message = "The server_tailscale_oauth_secret must be a Tailscale OAuth client secret (tskey-client-...), not an expiring auth key."
  }
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
  type = string
  # renovate: datasource=github-releases depName=tailscale/tailscale extractVersion=^v(?<version>.+)$
  default = "1.98.9" # static build embedded in the initramfs; bump via PR
}

variable "tailscale_apt_key_sha256" {
  type = string
  # SHA-256 of Tailscale's apt signing key (same value as the Ansible
  # tailscale role's tailscale_apt_key_sha256). A key rotation fails the
  # build loudly — verify upstream, then bump both.
  default = "3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39"
}

variable "boot_hostname" {
  type    = string
  default = "menegroth-server-boot" # the initramfs tailnet node name
}

variable "boot_tag" {
  type    = string
  default = "tag:boot-unlock"
}

variable "server_hostname" {
  type    = string
  default = "menegroth-server" # must match ansible_host (MagicDNS) in the inventory
}

variable "server_tag" {
  type    = string
  default = "tag:server"
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
      "TS_BOOT_OAUTH_SECRET=${var.boot_tailscale_oauth_secret}",
      "TS_SERVER_OAUTH_SECRET=${var.server_tailscale_oauth_secret}",
      "MAC_UNLOCK_PUBKEY=${var.mac_unlock_ssh_pubkey}",
      "UBUNTU_SERIES=${var.ubuntu_series}",
      "TAILSCALE_VERSION=${var.tailscale_version}",
      "TS_APT_KEY_SHA256=${var.tailscale_apt_key_sha256}",
      "BOOT_HOSTNAME=${var.boot_hostname}",
      "BOOT_TAG=${var.boot_tag}",
      "SERVER_HOSTNAME=${var.server_hostname}",
      "SERVER_TAG=${var.server_tag}",
    ]
  }
}
