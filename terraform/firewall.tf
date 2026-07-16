# Default posture: NO inbound rules — the host is fully dark and reachable
# only over the tailnet (Tailscale needs outbound UDP only, which Hetzner
# firewalls do not restrict).
#
# During initial buildout (before Tailscale is provisioned), setting
# bootstrap_admin_ip_cidr opens SSH to that single address so the first
# Ansible run can reach the box.
resource "hcloud_firewall" "server" {
  name = "${var.server_name}-fw"

  dynamic "rule" {
    for_each = var.bootstrap_admin_ip_cidr == null ? [] : [var.bootstrap_admin_ip_cidr]
    content {
      description = "Bootstrap SSH from admin IP only — removed in Phase 3"
      direction   = "in"
      protocol    = "tcp"
      port        = "22"
      source_ips  = [rule.value]
    }
  }
}
