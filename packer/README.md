# FDE image pipeline

Builds the Hetzner snapshot the server boots from: Ubuntu 26.04 with a
**LUKS2-encrypted root**, an unencrypted `/boot`, an initramfs that joins
the tailnet at the boot prompt so the Mac unlock agent (see `macos/`) can
deliver the passphrase, and a first-boot unit that joins the real system to
the tailnet so Ansible can reach a fresh server. See `docs/architecture.md`
D2 and D10 for the design and threat model.

## How it works

1. Packer boots a temporary cx33 into the Hetzner **rescue system**.
2. `scripts/install-fde.sh` partitions the disk (BIOS-boot / 1 GiB `/boot` /
   LUKS2 root), debootstraps Ubuntu, installs kernel + grub + cloud-init +
   `dropbear-initramfs` + the tailscale package, embeds the static tailscale
   binaries plus the boot node credential via the hooks in
   `files/initramfs/`, and installs `tailscale-firstboot.service`.
3. Packer snapshots the result with labels `fde=true, role=menegroth-server-base`;
   Terraform selects the newest matching snapshot (Phase 9).

At boot, servers built from this image: get DHCP networking in initramfs
(`ip=dhcp` on the kernel cmdline) → join the tailnet as an **ephemeral** node
(`menegroth-server-boot`, `tag:boot-unlock`; the CLI mints the key from the
OAuth client secret over HTTPS, hence the embedded CA roots + `resolv.conf`)
→ dropbear accepts the Mac agent's key (forced command `cryptroot-unlock`, no
forwarding) → root unlocks → the boot node logs itself out before pivoting to
the real system. On a server's **first** boot, `tailscale-firstboot` then
joins it as `menegroth-server` (`tag:server`, Tailscale SSH) and deletes its
credential.

If the tailnet join fails, boot gives up after ~3 minutes (bounded
`--timeout` + retries) and waits at the passphrase prompt — the Hetzner web
console always works as manual fallback.

## One-time prerequisites

All of these are produced by the bootstrap (README → "One-time bootstrap");
`scripts/bootstrap/preflight.sh` verifies them:

- Tailnet ACL defining `tag:server` and `tag:boot-unlock` (phase 20), and two
  **OAuth clients** (`auth_keys` scope, one tag each — never expiring auth
  keys, D10): `/ci/TS_SERVER_OAUTH_SECRET` and `/unlock/TS_BOOT_OAUTH_SECRET`.
- Root passphrase: generated **inside 1Password** (`luks-passphrase`, 40
  letters+digits so it stays typeable at the console), copied to Infisical
  `/unlock/ROOT_LUKS_KEY`.
- Mac unlock agent's SSH public key: `/unlock/MAC_UNLOCK_SSH_PUBKEY` (CI
  passes it as `PKR_VAR_mac_unlock_ssh_pubkey`; it is not in source).
- The `ci` Infisical identity reads `/ci` + `/unlock` (build-time only).

## Building

CI: run the "Packer FDE image" workflow via **workflow_dispatch** (PRs only
validate — a build spins up a paid cx33 for ~10–15 minutes).

Locally:

```bash
export HCLOUD_TOKEN=… PKR_VAR_root_luks_passphrase=… \
  PKR_VAR_boot_tailscale_oauth_secret=tskey-client-… \
  PKR_VAR_server_tailscale_oauth_secret=tskey-client-… \
  PKR_VAR_mac_unlock_ssh_pubkey='ssh-ed25519 …'
cd packer && packer init . && packer build .
```

(CI is the normal path — `CLAUDE.md`: Packer builds run via workflow_dispatch.)

## Verifying a new image (throwaway server, before Phase 9 rollout)

0. **Pause the Mac unlock agent** for the test, because it will rightly treat
   the throwaway's boot node (a different IP) as possible impersonation:
   `launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.menegroth-server.unlock.plist`
   (re-enable afterwards with `launchctl bootstrap` and the same arguments).
1. Create a server from the snapshot in the Hetzner console (give it a
   throwaway name; it will still join as `menegroth-server` — delete that
   node from the tailnet afterwards if production is already running).
2. Watch the tailnet: a `menegroth-server-boot` node appears within ~1
   minute (proves DNS + CA roots + OAuth exchange work in the initramfs).
3. **Prove the boot node's origin before sending the passphrase:**
   `tailscale ping --until-direct <boot-node-tailnet-ip>` must end with
   `via <throwaway's public IPv4>:<port>`, matching the IP the Hetzner console
   shows for the throwaway. This is the check the agent automates
   (`docs/troubleshooting.md`). Only then `ssh root@<boot-node-tailnet-ip>` →
   forced `cryptroot-unlock` prompts → server boots; the boot node disappears, and
   a `tag:server` node joins (first-boot unit); on the server,
   `/etc/tailscale-firstboot/authkey` is gone.
4. Reboot and unlock via the Hetzner web console instead, following
   `docs/troubleshooting.md` §8.
5. `apt install --reinstall linux-image-generic` (forces initramfs rebuild),
   reboot, confirm the tailnet join still works — this is the kernel-update
   survival test.
6. Delete the throwaway server; re-enable the Mac agent (step 0).

## Notes

- The boot OAuth client secret and tailscale binaries live inside the
  initramfs on the unencrypted `/boot`. The secret does not expire, so if
  disk compromise is ever suspected, **revoke the OAuth client**, create a
  new one, and rebuild (`docs/runbooks/key-rotation.md`); nodes it creates
  are ephemeral and tag-restricted.
- Bump `tailscale_version` deliberately via PR (Renovate groups it); the
  initramfs copy is independent of the running system's tailscale package.
- After the image changes (new credential, new tailscale version), rebuild
  and re-verify steps 1–5 before rolling to production.
