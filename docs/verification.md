# Deployment verification checklist

Run these end-to-end checks after first deployment (and the relevant subset
after any significant change). They mirror the build phases.

## Infrastructure & CI

- [ ] A PR touching `terraform/` gets a plan comment; merge applies cleanly.
- [ ] Re-running the Terraform workflow shows **no drift** (empty plan).
- [ ] A PR touching `ansible/` runs ansible-lint + syntax check.

## Hardening

- [ ] `ansible-playbook site.yml` twice in a row → second run reports 0 changes.
- [ ] `ssh root@server` and password auth are refused.
- [ ] `sudo unattended-upgrade --dry-run --debug` shows security origins active.
- [ ] Optional: `sudo lynis audit system` — record the score as a baseline.

## Network posture

- [ ] From outside the tailnet: `nmap -Pn <public-ip>` shows **no open ports**.
- [ ] From a tailnet device: `ssh admin@ai-server` works (Tailscale SSH).
- [ ] The Ansible provision job (runner joins tailnet) succeeds on merge.

## FDE root & automated unlock

- [ ] Fresh image (throwaway server): boot node appears on the tailnet within
      ~1 min; manual `ssh root@<boot-node>` unlock works; Hetzner console
      passphrase entry works (`packer/README.md` steps 1–5).
- [ ] Kernel-update survival: reinstall the kernel package, reboot, boot node
      still joins (initramfs hook re-embedded tailscale).
- [ ] Hands-off `sudo reboot` → Mac agent unlocks within ~2–3 min, ntfy
      "unlocked" notification arrives, all services recover.
- [ ] Mac asleep during reboot → server waits; on wake the agent unlocks;
      after 10+ min stuck, the urgent "STUCK at boot" ntfy fires.
- [ ] The boot node disappears from the tailnet after pivot (ephemeral +
      logout), and `tailscale status` on the running server shows only the
      real node.
- [ ] Server identity CANNOT read `/unlock`: `sudo infisical-get ROOT_LUKS_KEY`
      on the server must FAIL.

## Secrets & encrypted volume

- [ ] On the server: `sudo infisical-get --check` exits 0.
- [ ] `git grep -iE 'client_secret|BEGIN.*KEY'` in this repo finds nothing real;
      CI logs show no secret values (spot-check a run).
- [ ] `sudo systemctl reboot` → within ~2 minutes `/data` is mounted again
      with no human involved (`mountpoint /data`).
- [ ] `sudo cryptsetup luksDump $(ls /dev/disk/by-id/scsi-0HC_Volume_*)`
      shows LUKS2 with one keyslot.

## Agent runtime

- [ ] As the nemoclaw user: onboard and run one sample agent end-to-end.
- [ ] Blocked egress actually blocks: from inside the sandbox, `curl` a
      non-allowlisted host and confirm it fails.
- [ ] `systemctl show user-1500.slice -p MemoryMax` reflects the configured cap.
- [ ] Agent state lands under `/data/nemoclaw` (`du -sh /data/nemoclaw`).

## Operations

- [ ] Force an alert: `sudo systemctl start server-healthcheck.service` with
      tailscaled stopped → ntfy notification arrives; restart tailscaled.
- [ ] Hetzner console shows daily server backups enabled.
- [ ] If restic is enabled: `restic snapshots` lists last night's backup, and
      a test `restic restore latest --target /tmp/restore-drill` succeeds.
- [ ] Walk `docs/runbooks/break-glass.md` once for real: open the Hetzner
      console and confirm you can reach a shell via rescue mode.
