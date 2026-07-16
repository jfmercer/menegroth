resource "hcloud_ssh_key" "admin" {
  name       = "${var.server_name}-admin"
  public_key = var.admin_ssh_public_key
}

resource "hcloud_server" "ai" {
  name         = var.server_name
  server_type  = var.server_type
  image        = var.image
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

  # cloud-init contents change forces replacement otherwise; the server is
  # provisioned by Ansible after creation, so ignore later user_data edits.
  lifecycle {
    ignore_changes = [user_data]
  }
}
