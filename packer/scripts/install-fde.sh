#!/usr/bin/env bash
# Runs inside the Hetzner RESCUE system (Packer `rescue = "linux64"`).
# Installs Ubuntu 26.04 with a LUKS2-encrypted root, an unencrypted /boot,
# and an initramfs that joins the tailnet (static tailscaled) and accepts
# the unlock passphrase over dropbear. The result is snapshotted by Packer.
set -euo pipefail

: "${LUKS_PASSPHRASE:?}" "${TS_BOOT_AUTHKEY:?}" "${MAC_UNLOCK_PUBKEY:?}"
: "${UBUNTU_SERIES:=resolute}" "${TAILSCALE_VERSION:?}" "${BOOT_HOSTNAME:=menegroth-server-boot}"

DISK=/dev/sda
BOOT_PART=${DISK}2
LUKS_PART=${DISK}3
MAPPER=root_crypt
TARGET=/mnt/target
FILES=/tmp/fde-files

echo "=== 1/8 Partitioning $DISK (GPT: bios_grub, /boot, LUKS root)"
sfdisk --wipe always "$DISK" <<'PARTS'
label: gpt
size=1MiB, type=21686148-6449-6E6F-744E-656564454649
size=1GiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
PARTS
udevadm settle

echo "=== 2/8 LUKS2 format + filesystems"
printf '%s' "$LUKS_PASSPHRASE" \
  | cryptsetup luksFormat --type luks2 --batch-mode "$LUKS_PART" --key-file=-
printf '%s' "$LUKS_PASSPHRASE" \
  | cryptsetup open "$LUKS_PART" "$MAPPER" --key-file=-
mkfs.ext4 -q -L boot "$BOOT_PART"
mkfs.ext4 -q -L root "/dev/mapper/$MAPPER"

echo "=== 3/8 debootstrap $UBUNTU_SERIES"
mkdir -p "$TARGET"
mount "/dev/mapper/$MAPPER" "$TARGET"
mkdir -p "$TARGET/boot"
mount "$BOOT_PART" "$TARGET/boot"
apt-get update -qq
apt-get install -y -qq debootstrap
# Pass the generic `gutsy` script explicitly: every Ubuntu suite script is a
# symlink to it, so this succeeds even if the rescue system's debootstrap
# predates the target suite and would otherwise abort with "No such script".
debootstrap --arch=amd64 "$UBUNTU_SERIES" "$TARGET" http://archive.ubuntu.com/ubuntu gutsy

echo "=== 4/8 Base system configuration"
LUKS_UUID="$(blkid -s UUID -o value "$LUKS_PART")"
BOOT_UUID="$(blkid -s UUID -o value "$BOOT_PART")"

cat > "$TARGET/etc/fstab" <<EOF
/dev/mapper/$MAPPER /     ext4 defaults 0 1
UUID=$BOOT_UUID     /boot ext4 defaults 0 2
EOF
echo "$MAPPER UUID=$LUKS_UUID none luks,discard" > "$TARGET/etc/crypttab"

cat > "$TARGET/etc/apt/sources.list" <<EOF
deb http://archive.ubuntu.com/ubuntu $UBUNTU_SERIES main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $UBUNTU_SERIES-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $UBUNTU_SERIES-security main restricted universe multiverse
EOF

for fs in dev proc sys run; do
  mount --rbind "/$fs" "$TARGET/$fs"
  mount --make-rslave "$TARGET/$fs"
done
cp /etc/resolv.conf "$TARGET/etc/resolv.conf"

echo "=== 5/8 Install kernel, grub, cryptsetup, dropbear, cloud-init"
chroot "$TARGET" env DEBIAN_FRONTEND=noninteractive bash -s <<'CHROOT'
set -euo pipefail
apt-get update -qq
apt-get install -y -qq \
  linux-image-generic grub-pc \
  cryptsetup cryptsetup-initramfs dropbear-initramfs busybox-initramfs \
  openssh-server cloud-init netplan.io sudo python3 \
  curl ca-certificates iproute2
CHROOT

echo "=== 6/8 Initramfs: dropbear + tailscale"
# Dropbear: key-only, forced command, no forwarding, generous unlock window.
mkdir -p "$TARGET/etc/dropbear/initramfs"
cat > "$TARGET/etc/dropbear/initramfs/dropbear.conf" <<'EOF'
DROPBEAR_OPTIONS="-I 600 -j -k -s -p 22"
EOF
printf 'no-port-forwarding,no-agent-forwarding,command="cryptroot-unlock" %s\n' \
  "$MAC_UNLOCK_PUBKEY" > "$TARGET/etc/dropbear/initramfs/authorized_keys"
chmod 600 "$TARGET/etc/dropbear/initramfs/authorized_keys"

# Static tailscale binaries for the initramfs (Go static build).
curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz" \
  -o /tmp/tailscale.tgz
mkdir -p "$TARGET/usr/lib/tailscale-initramfs"
tar -xzf /tmp/tailscale.tgz -C "$TARGET/usr/lib/tailscale-initramfs" \
  --strip-components=1 \
  "tailscale_${TAILSCALE_VERSION}_amd64/tailscaled" \
  "tailscale_${TAILSCALE_VERSION}_amd64/tailscale"

# Boot node credentials/config. NOTE: these are embedded into the initramfs
# image on the UNENCRYPTED /boot partition — that is the accepted trade-off
# (see docs/architecture.md D2). The auth key is ephemeral + pre-authorized
# + restricted to tag:boot-unlock, and revocable in the admin console.
mkdir -p "$TARGET/etc/tailscale-boot"
printf '%s\n' "$TS_BOOT_AUTHKEY" > "$TARGET/etc/tailscale-boot/authkey"
printf '%s\n' "$BOOT_HOSTNAME" > "$TARGET/etc/tailscale-boot/hostname"
chmod 700 "$TARGET/etc/tailscale-boot"
chmod 600 "$TARGET/etc/tailscale-boot/authkey"

# initramfs-tools hook + boot scripts (from packer/files/initramfs/).
install -m 0755 "$FILES/initramfs/tailscale-hook" \
  "$TARGET/etc/initramfs-tools/hooks/tailscale"
install -m 0755 "$FILES/initramfs/tailscale-premount" \
  "$TARGET/etc/initramfs-tools/scripts/init-premount/tailscale"
install -m 0755 "$FILES/initramfs/tailscale-bottom" \
  "$TARGET/etc/initramfs-tools/scripts/init-bottom/tailscale"

echo "=== 7/8 Grub + initramfs build"
chroot "$TARGET" env DEBIAN_FRONTEND=noninteractive bash -s <<'CHROOT'
set -euo pipefail
# ip=dhcp lets initramfs-tools' configure_networking bring eth0 up before
# tailscaled starts.
sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="ip=dhcp"/' /etc/default/grub
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
grub-install /dev/sda
update-grub
update-initramfs -c -k all

# Hetzner datasource for cloud-init so Terraform user_data keeps working
# on servers created from this snapshot.
printf 'datasource_list: [Hetzner, None]\n' \
  > /etc/cloud/cloud.cfg.d/90-hetzner.cfg
cat > /etc/netplan/50-dhcp.yaml <<'EOF'
network:
  version: 2
  ethernets:
    all:
      match: { name: "e*" }
      dhcp4: true
      dhcp6: true
EOF
chmod 600 /etc/netplan/50-dhcp.yaml

# Fresh identity on first boot from the snapshot.
truncate -s 0 /etc/machine-id
passwd -l root
CHROOT

echo "=== 8/8 Teardown"
# Belt-and-braces: ensure no secrets linger outside their intended files.
rm -f "$TARGET/etc/resolv.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"
sync
umount -R "$TARGET/dev" "$TARGET/proc" "$TARGET/sys" "$TARGET/run" || true
umount "$TARGET/boot"
umount "$TARGET"
cryptsetup close "$MAPPER"
echo "FDE image build complete — Packer will now snapshot."
