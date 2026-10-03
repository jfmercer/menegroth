# Rotating LUKS keys

## Root volume passphrase

The root passphrase lives in the 1Password `Menegroth` vault
(primary; item `luks-passphrase`) and Infisical `/unlock/ROOT_LUKS_KEY`
(recovery). On the server (as root):

```bash
# 1. Generate the new passphrase IN 1PASSWORD (password generator, 40
#    letters+digits — typeable at the Hetzner console, like the original from
#    scripts/bootstrap/10-onepassword.sh), saved as a NEW item
#    (e.g. luks-passphrase-new) so the current one stays intact; then stage
#    it in Infisical as /unlock/ROOT_LUKS_KEY_NEW.

# 2. Add it to a free keyslot (current passphrase still valid):
#    cryptsetup will prompt for an existing passphrase, then the new one:
cryptsetup luksAddKey /dev/sda4

# 3. Verify, then update BOTH stores:
#    - Infisical: overwrite /unlock/ROOT_LUKS_KEY, delete the _NEW entry
#    - 1Password: copy the new value into the luks-passphrase item IN THE APP
#      (avoid putting it on an `op` command line — argv is visible to other
#      processes), then delete luks-passphrase-new

# 4. Remove the old keyslot:
cryptsetup luksRemoveKey /dev/sda4   # supply the OLD passphrase

# 5. Prove end-to-end: reboot; the Mac agent must unlock with the new key.
systemctl reboot
```

## Tailscale OAuth clients (boot node and first-boot join)

Both image-embedded tailnet credentials are OAuth client secrets (D10) — they
never expire, so rotation is only needed on suspected exposure (e.g. a leaked
disk image for the `/boot` copy) or as hygiene:

1. Tailscale admin console → Settings → OAuth clients → create a replacement
   (`auth_keys` scope, same single tag: `tag:boot-unlock` or `tag:server`).
2. Overwrite `/unlock/TS_BOOT_OAUTH_SECRET` or `/ci/TS_SERVER_OAUTH_SECRET`
   in Infisical (the bootstrap never overwrites existing secrets).
3. Rebuild the image (Packer workflow) and roll the server (below).
4. **Revoke the old OAuth client.** Do this last for the `tag:server` client
   only if nothing still needs it — a running server already has its node
   identity and does not use the client again.

## Rolling the server onto a new image

```bash
# 1. Remove the old node from the tailnet FIRST (admin console → Machines →
#    menegroth-server → Remove). Otherwise the new server's first-boot join
#    gets the name menegroth-server-1, and Ansible (MagicDNS menegroth-server)
#    keeps targeting the dead node.
# 2. Roll (on master, via CI — or locally only in an emergency):
terraform apply -replace=hcloud_server.menegroth
# 3. The new server waits at the unlock prompt; the Mac agent unlocks it;
#    tailscale-firstboot joins it as menegroth-server. Then re-run the
#    Ansible workflow (Actions → Ansible → Re-run) to provision it.
```

The public IPs are Hetzner **Primary IPs** that survive the replacement, so
the Mac agent's origin check (`SERVER_IPV4`) keeps working with no change.

**After any image roll:** the new image carries freshly generated dropbear
host keys. The Mac unlock agent pins host keys by boot-node IP in
`~/.local/state/menegroth-server-unlock/known_hosts`
(`StrictHostKeyChecking=accept-new`), so if the new boot node comes up on a
tailnet IP an old image once used, the unlock SSH hard-fails on the key
mismatch and reboots stop being hands-free. Clear the pin cache on the Mac
after every image roll:

```bash
rm -f ~/.local/state/menegroth-server-unlock/known_hosts
```

## Data-volume LUKS key

The volume passphrase lives in Infisical at `/server/DATA_VOLUME_LUKS_KEY`.
Rotation changes the LUKS keyslot **and** the Infisical secret, in an order
that never leaves the volume unlockable.

On the server (over Tailscale SSH, as root):

```bash
# 1. Generate the new key and store it in Infisical FIRST, as a second
#    secret so the old one still works if anything below fails:
new_key=$(openssl rand -base64 48)
#    → create /server/DATA_VOLUME_LUKS_KEY_NEW with this value (console or CLI)

# 2. Add the new key to a free LUKS keyslot (old key still valid):
device=$(ls /dev/disk/by-id/scsi-0HC_Volume_*)
/usr/local/bin/infisical-get DATA_VOLUME_LUKS_KEY > /dev/shm/old && \
printf '%s' "$new_key" > /dev/shm/new && \
cryptsetup luksAddKey "$device" /dev/shm/new --key-file=/dev/shm/old

# 3. Verify the new key opens the volume:
printf '%s' "$new_key" | cryptsetup open --test-passphrase "$device" --key-file=-

# 4. In Infisical: overwrite /server/DATA_VOLUME_LUKS_KEY with the new value,
#    delete DATA_VOLUME_LUKS_KEY_NEW.

# 5. Remove the old keyslot and scrub temp files:
cryptsetup luksRemoveKey "$device" /dev/shm/old
shred -u /dev/shm/old /dev/shm/new

# 6. Prove end-to-end: reboot and confirm /data comes back.
systemctl reboot
```

`/dev/shm` is RAM-backed; nothing key-shaped touches persistent disk.

Rotate the **machine identity** (which can fetch the key) separately in the
Infisical console: Identities → server → Universal Auth → rotate client
secret, then re-run the Ansible workflow to push the new credential.
