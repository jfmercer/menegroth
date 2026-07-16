# Encrypted data volume. Terraform leaves it raw; the Ansible luks_volume
# role LUKS2-formats it on first run and mounts it at /data. Everything
# sensitive on the server lives on this volume.
resource "hcloud_volume" "data" {
  name              = "${var.server_name}-data"
  size              = var.data_volume_size
  location          = var.location
  delete_protection = true
}

resource "hcloud_volume_attachment" "data" {
  volume_id = hcloud_volume.data.id
  server_id = hcloud_server.ai.id
  automount = false
}

output "data_volume_device" {
  description = "Stable device path of the data volume on the server"
  value       = hcloud_volume.data.linux_device
}
