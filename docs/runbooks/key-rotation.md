# Rotating LUKS keys

## Root volume passphrase

The root passphrase lives in the 1Password `Menegroth` vault
(primary; item `luks-passphrase`) and Infisical `/unlock/ROOT_LUKS_KEY`
(recovery). On the server (as root):

```bash
# 1. Generate and stage the new passphrase:
new_key=$(openssl rand -base64 48)
#    → update Infisical /unlock/ROOT_LUKS_KEY_NEW with it

# 2. Add it to a free keyslot (current passphrase still valid):
#    cryptsetup will prompt for an existing passphrase, then the new one:
cryptsetup luksAddKey /dev/sda3

# 3. Verify, then update BOTH stores:
#    - Infisical: overwrite /unlock/ROOT_LUKS_KEY, delete the _NEW entry
#    - 1Password: edit the luks-passphrase item IN THE APP (avoid putting
#      the value on an `op` command line — argv is visible to other processes)

# 4. Remove the old keyslot:
cryptsetup luksRemoveKey /dev/sda3   # supply the OLD passphrase

# 5. Prove end-to-end: reboot; the Mac agent must unlock with the new key.
systemctl reboot
```

Rotate the **boot node auth key** (initramfs tailnet identity) by generating
a new ephemeral pre-authorized key, updating `/unlock/TS_BOOT_AUTHKEY`,
rebuilding the image (Packer workflow), rolling the server
(`terraform apply -replace=hcloud_server.ai`), and revoking the old key in
the Tailscale admin console.

**After any image roll** (this rotation or any other rebuild): the new image
carries freshly generated dropbear host keys. The Mac unlock agent pins host
keys by boot-node IP in `~/.local/state/ai-server-unlock/known_hosts`
(`StrictHostKeyChecking=accept-new`), so if the new boot node comes up on a
tailnet IP an old image once used, the unlock SSH hard-fails on the key
mismatch and reboots stop being hands-free. Clear the pin cache on the Mac
after every image roll:

```bash
rm -f ~/.local/state/ai-server-unlock/known_hosts
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
