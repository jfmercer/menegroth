output "server_ipv4" {
  description = "Public IPv4 (stable Primary IP). The Mac unlock agent's SERVER_IPV4 (macos/install.sh); never used for day-to-day access, which is over the tailnet"
  value       = hcloud_primary_ip.v4.ip_address
}

output "server_ipv6" {
  description = "Public IPv6 address of the server"
  value       = hcloud_server.menegroth.ipv6_address
}

output "server_ipv6_network" {
  description = "Public IPv6 /64 (stable Primary IP). The Mac unlock agent's SERVER_IPV6_NET (macos/install.sh)"
  value       = hcloud_primary_ip.v6.ip_network
}

output "server_status" {
  value = hcloud_server.menegroth.status
}
