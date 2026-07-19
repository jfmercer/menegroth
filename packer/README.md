# FDE image pipeline

Builds the Hetzner snapshot the server boots from: Ubuntu 24.04 with a
**LUKS2-encrypted root**, an unencrypted `/boot`, and an initramfs that joins
the tailnet at the boot prompt so the Mac unlock agent (see `macos/`) can
deliver the passphrase. See `docs/architecture.md` D2 for the design and
threat model.

## How it works

1. Packer boots a temporary cx33 into the Hetzner **rescue system**.
2. `scripts/install-fde.sh` partitions the disk (BIOS-boot / 1 GiB `/boot` /
   LUKS2 root), debootstraps Ubuntu, installs kernel + grub + cloud-init +
   `dropbear-initramfs`, and embeds the static tailscale binaries plus the
   boot node credentials via the hooks in `files/initramfs/`.
3. Packer snapshots the result with labels `fde=true, role=menegroth-server-base`;
   Terraform selects the newest matching snapshot (Phase 9).

At boot, servers built from this image: get DHCP networking in initramfs
(`ip=dhcp` on the kernel cmdline) → join the tailnet as an **ephemeral** node
(`menegroth-server-boot`, `tag:boot-unlock`) → dropbear accepts the Mac agent's key
(forced command `cryptroot-unlock`, no forwarding) → root unlocks → the boot
node logs itself out before pivoting to the real system.

If the tailnet join fails, boot simply waits at the passphrase prompt — the
Hetzner web console always works as manual fallback.

## One-time prerequisites

- Tailnet ACLs: add `tag:boot-unlock` (owner: you) and rules so only your
  devices can reach `tag:boot-unlock:22`, and the tag can initiate nothing.
- Tailscale admin console → generate a **reusable, ephemeral, pre-authorized**
  auth key restricted to `tag:boot-unlock`; store it in Infisical at
  `/unlock/TS_BOOT_AUTHKEY`.
- Generate the root passphrase (`openssl rand -base64 48`); store it in
  Infisical at `/unlock/ROOT_LUKS_KEY` **and** in the 1Password
  `Menegroth` vault (`macos/README.md`).
- Put the Mac unlock agent's SSH **public** key in `fde-image.pkr.hcl`
  (`mac_unlock_ssh_pubkey`).
- Grant the CI machine identity read access to `/unlock` (build-time only).

## Building

CI: run the "Packer FDE image" workflow via **workflow_dispatch** (PRs only
validate — a build spins up a paid cx33 for ~10–15 minutes).

Locally:

```bash
export HCLOUD_TOKEN=… PKR_VAR_root_luks_passphrase=… PKR_VAR_boot_tailscale_authkey=…
cd packer && packer init . && packer build .
```

## Verifying a new image (throwaway server, before Phase 9 rollout)

1. Create a server from the snapshot in the Hetzner console.
2. Watch the tailnet: an `menegroth-server-boot` node appears within ~1 minute.
3. `ssh root@<boot-node>` from an authorized device → forced
   `cryptroot-unlock` prompts → server boots; the boot node disappears.
4. Reboot and unlock via the Hetzner web console instead (type passphrase).
5. `apt install --reinstall linux-image-generic` (forces initramfs rebuild),
   reboot, confirm the tailnet join still works — this is the kernel-update
   survival test.
6. Delete the throwaway server.

## Notes

- The boot auth key and tailscale binaries live inside the initramfs on the
  unencrypted `/boot`. Rotate the auth key (rebuild image) if disk compromise
  is ever suspected; the node is ephemeral, tag-restricted, and revocable.
- Bump `tailscale_version` deliberately via PR; the initramfs copy is
  independent of the running system's tailscale package.
- After the image changes (new auth key, new tailscale version), rebuild and
  re-verify steps 1–5 before rolling to production (Phase 9 apply).
