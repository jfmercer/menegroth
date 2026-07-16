resource "hcloud_ssh_key" "admin" {
  name       = "${var.server_name}-admin"
  public_key = var.admin_ssh_public_key
}

# Newest FDE snapshot from the Packer pipeline. New snapshots do NOT
# auto-replace the server (see ignore_changes below); roll deliberately with:
#   terraform apply -replace=hcloud_server.ai
data "hcloud_image" "fde" {
  with_selector     = var.fde_image_selector
  most_recent       = true
  with_architecture = "x86"
}

resource "hcloud_server" "ai" {
  name         = var.server_name
  server_type  = var.server_type
  image        = data.hcloud_image.fde.id
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.server.id]

  # Hetzner-managed daily server backups (7 rotating slots, +20% server
  # price). Covers the root disk; /data is covered by its own LUKS-encrypted
  # volume + optional restic (ops role).
  backups = true

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    admin_user           = var.admin_user
    admin_ssh_public_key = var.admin_ssh_public_key
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # user_data: cloud-init edits would force replacement; Ansible owns
  # post-create config. image: a newer FDE snapshot must not silently
  # replace the server — roll with `terraform apply -replace=hcloud_server.ai`
  # after verifying the new image (packer/README.md).
  lifecycle {
    ignore_changes = [user_data, image]
  }
}
