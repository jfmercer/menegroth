# Break-glass access

The server has **no public inbound ports**. If Tailscale is down, broken by an
upgrade, or the tailnet ACLs lock you out, use one of these paths — in order.

## 1. Hetzner web console (always works)

1. Log in to <https://console.hetzner.cloud> → project → `ai-server`.
2. Open the **Console** (>_ icon). This is out-of-band VGA access; it works
   regardless of network/firewall state.
3. Console login needs a password, and all password logins are disabled.
   Either:
   - boot into the Hetzner **rescue system** (Server → Rescue → Enable rescue
     & power cycle), mount the root disk, `chroot` and fix; or
   - if you previously set a root password for emergencies (not default), log
     in directly.
4. Typical fixes: `systemctl restart tailscaled`, `tailscale up`, inspect
   `journalctl -u tailscaled`.

## 2. Temporary public SSH via Terraform

If you need a real shell and the console is too painful:

1. Edit `terraform/variables.tf` → set `bootstrap_admin_ip_cidr` to
   `"<your-ip>/32"` (or apply with `-var bootstrap_admin_ip_cidr=…`).
2. Merge (or run `terraform apply` locally with `HCLOUD_TOKEN` from Infisical).
3. `ssh admin@$(terraform output -raw server_ipv4)` using the bootstrap key
   from Infisical `/ci/SSH_PRIVATE_KEY`.
4. **Revert to `null` and re-apply as soon as you're done.** The host `ufw`
   still allows port 22, so the cloud firewall is the only thing between the
   internet and sshd while this rule exists.

## 3. Nuke and repave

The server is fully reproducible. If it's compromised or unrecoverable:

```bash
terraform destroy -target=hcloud_server.ai && terraform apply
# then let the Ansible workflow re-provision (or run site.yml manually)
```

The data volume is separate from the server; re-attach it and the
`luks_volume` role restores `/data` (key comes from Infisical, not the dead
server). See `restore.md`.
