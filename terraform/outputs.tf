output "server_ipv4" {
  description = "Public IPv4 (bootstrap access only — day-to-day access is over the tailnet)"
  value       = hcloud_server.menegroth.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6"
  value       = hcloud_server.menegroth.ipv6_address
}

output "server_status" {
  value = hcloud_server.menegroth.status
}
