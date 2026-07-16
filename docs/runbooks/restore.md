# Restore / rebuild

## Server died or is compromised — volume intact

The server is disposable; the data volume and secrets are not on it.

1. `terraform destroy -target=hcloud_server.ai` (volume has
   `delete_protection` and its attachment simply follows the new server).
2. `terraform apply` — recreates the server and re-attaches the volume.
3. Run the Ansible workflow (or `ansible-playbook site.yml`). The
   `luks_volume` role detects the existing LUKS container (it only formats
   blank devices) and mounts it; NemoClaw state under `/data` reappears.
4. If the old server may have been compromised: rotate the server machine
   identity client secret and the LUKS key (see `key-rotation.md`), and
   revoke its Tailscale node in the admin console.

## Volume lost or corrupted

1. Remove `delete_protection` in `terraform/volume.tf` only if you are
   deliberately destroying it; otherwise create a fresh volume by bumping the
   name.
2. Apply; the `luks_volume` role formats the blank volume on the next run.
3. Restore `/data` content from backups (see the ops role — restic, if
   enabled) — `restic restore latest --target /data`.

## Total loss (Hetzner project gone)

Everything needed to rebuild is: this repo + the Infisical project + the
Tailscale account + HCP Terraform state (recreatable from scratch if lost —
resources are few). Walk the README bootstrap section again.
