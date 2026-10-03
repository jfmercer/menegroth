#!/usr/bin/env bash
# Runs inside the Hetzner RESCUE system (Packer `rescue = "linux64"`).
# Installs Ubuntu 26.04 with a LUKS2-encrypted root, an unencrypted /boot,
# an initramfs that joins the tailnet (static tailscaled) and accepts the
# unlock passphrase over dropbear, and a first-boot unit that joins the real
# system to the tailnet (D10). The result is snapshotted by Packer.
set -euo pipefail

: "${LUKS_PASSPHRASE:?}" "${TS_BOOT_OAUTH_SECRET:?}" "${TS_SERVER_OAUTH_SECRET:?}" "${MAC_UNLOCK_PUBKEY:?}"
: "${UBUNTU_SERIES:=resolute}" "${TAILSCALE_VERSION:?}" "${TS_APT_KEY_SHA256:?}"
: "${UBUNTU_KEYRING_VERSION:?}" "${UBUNTU_KEYRING_DEB_SHA256:?}"
: "${BOOT_HOSTNAME:=menegroth-server-boot}" "${BOOT_TAG:=tag:boot-unlock}"
: "${SERVER_HOSTNAME:=menegroth-server}" "${SERVER_TAG:=tag:server}"

DISK=/dev/sda
ESP_PART=${DISK}2
BOOT_PART=${DISK}3
LUKS_PART=${DISK}4
MAPPER=root_crypt
TARGET=/mnt/target
FILES=/tmp/fde-files

echo "=== 1/8 Partitioning $DISK (GPT: bios_grub, ESP, /boot, LUKS root)"
apt-get update -qq
apt-get install -y -qq debootstrap dosfstools
# Hybrid boot, like Hetzner's own images: the server types differ in firmware
# (the CPX32 boots UEFI; others boot legacy BIOS), and a snapshot must boot on
# either. bios_grub serves BIOS; the EFI System Partition serves UEFI.
sfdisk --wipe always "$DISK" <<'PARTS'
label: gpt
size=1MiB, type=21686148-6449-6E6F-744E-656564454649
size=256MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
size=1GiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
PARTS
udevadm settle

echo "=== 2/8 LUKS2 format + filesystems"
printf '%s' "$LUKS_PASSPHRASE" \
  | cryptsetup luksFormat --type luks2 --batch-mode "$LUKS_PART" --key-file=-
printf '%s' "$LUKS_PASSPHRASE" \
  | cryptsetup open "$LUKS_PART" "$MAPPER" --key-file=-
mkfs.vfat -F 32 -n EFI "$ESP_PART" >/dev/null
mkfs.ext4 -q -L boot "$BOOT_PART"
mkfs.ext4 -q -L root "/dev/mapper/$MAPPER"

echo "=== 3/8 debootstrap $UBUNTU_SERIES"
mkdir -p "$TARGET"
mount "/dev/mapper/$MAPPER" "$TARGET"
mkdir -p "$TARGET/boot"
mount "$BOOT_PART" "$TARGET/boot"
mkdir -p "$TARGET/boot/efi"
mount "$ESP_PART" "$TARGET/boot/efi"
# Ubuntu's archive keys: the rescue system is Debian, which lacks them by
# default — without them debootstrap only WARNS and installs unverified
# packages fetched over plain HTTP. Debian's own ubuntu-keyring package can't
# be relied on (bookworm, the rescue base, dropped it from main), so fetch
# Ubuntu's package from the target series' release pocket (immutable once the
# series is released). It arrives over plain HTTP, so the SHA-256 pin is the
# trust anchor. --keyring makes signature verification mandatory (a
# missing/rotated key fails the build loudly).
kr_deb=/tmp/ubuntu-keyring.deb
curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring/ubuntu-keyring_${UBUNTU_KEYRING_VERSION}_all.deb" \
  -o "$kr_deb"
printf '%s  %s\n' "$UBUNTU_KEYRING_DEB_SHA256" "$kr_deb" | sha256sum -c --quiet -
dpkg-deb -x "$kr_deb" /tmp/ubuntu-keyring
# Pass the generic `gutsy` script explicitly: every Ubuntu suite script is a
# symlink to it, so this succeeds even if the rescue system's debootstrap
# predates the target suite and would otherwise abort with "No such script".
debootstrap --arch=amd64 \
  --keyring=/tmp/ubuntu-keyring/usr/share/keyrings/ubuntu-archive-keyring.gpg \
  "$UBUNTU_SERIES" "$TARGET" http://archive.ubuntu.com/ubuntu gutsy

echo "=== 4/8 Base system configuration"
LUKS_UUID="$(blkid -s UUID -o value "$LUKS_PART")"
BOOT_UUID="$(blkid -s UUID -o value "$BOOT_PART")"
ESP_UUID="$(blkid -s UUID -o value "$ESP_PART")"

cat > "$TARGET/etc/fstab" <<EOF
/dev/mapper/$MAPPER /         ext4 defaults 0 1
UUID=$BOOT_UUID     /boot     ext4 defaults 0 2
UUID=$ESP_UUID      /boot/efi vfat umask=0077 0 1
EOF
# `initramfs`: always unlock this device in the initramfs, rather than relying
# on the cryptroot hook detecting it as the root device from inside a chroot.
echo "$MAPPER UUID=$LUKS_UUID none luks,discard,initramfs" > "$TARGET/etc/crypttab"

# deb822 sources (the Ubuntu default since 24.04; apt 3 flags the one-line
# sources.list format as legacy). debootstrap writes a one-line sources.list —
# remove it so the archive isn't listed twice.
rm -f "$TARGET/etc/apt/sources.list"
cat > "$TARGET/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: $UBUNTU_SERIES $UBUNTU_SERIES-updates
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: $UBUNTU_SERIES-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

for fs in dev proc sys run; do
  mount --rbind "/$fs" "$TARGET/$fs"
  mount --make-rslave "$TARGET/$fs"
done
# DNS for the chroot. debootstrap leaves /etc/resolv.conf as systemd-resolved's
# relative symlink into /run, which now resolves through the rbind to the
# rescue system's own file — so replace the link with a plain copy of the
# rescue resolver config (dereferenced). Step 8 restores the symlink.
rm -f "$TARGET/etc/resolv.conf"
cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"

echo "=== 5/8 Install kernel, grub, cryptsetup, dropbear, cloud-init, tailscale"
chroot "$TARGET" env DEBIAN_FRONTEND=noninteractive \
  UBUNTU_SERIES="$UBUNTU_SERIES" TS_APT_KEY_SHA256="$TS_APT_KEY_SHA256" bash -s <<'CHROOT'
set -euo pipefail
apt-get update -qq
# GRUB: the UEFI package plus Ubuntu's signed shim (boots with Secure Boot on
# or off), and grub-pc-bin for the BIOS fallback (grub-pc itself Conflicts
# with grub-efi-amd64). Snapshots carry no firmware boot entries, so GRUB
# must also go to the removable path (EFI/BOOT/BOOTX64.EFI), on install and on
# every later GRUB upgrade, and never touch NVRAM. Ubuntu's grub-install does
# the extra removable install by default (only --no-extra-removable turns it
# off); pin the debconf answer the upgrade postinst consults.
debconf-set-selections <<'DEBCONF'
grub-efi-amd64 grub2/no_efi_extra_removable boolean false
grub-efi-amd64 grub2/update_nvram boolean false
DEBCONF
# initramfs-tools explicitly: the kernel now Recommends dracut (which
# Conflicts with initramfs-tools), but the unlock path — dropbear-initramfs and
# the hooks in packer/files/initramfs/ — is built on initramfs-tools.
apt-get install -y -qq \
  linux-image-generic initramfs-tools \
  grub-efi-amd64 grub-efi-amd64-signed shim-signed grub-pc-bin dosfstools \
  cryptsetup cryptsetup-initramfs dropbear-initramfs busybox-initramfs \
  openssh-server cloud-init netplan.io sudo python3 \
  curl ca-certificates iproute2

# The real system's tailscale (the package the Ansible tailscale role
# manages — same keyring path and repo line, so the role is a no-op on it).
# Needed here so a fresh server can join the tailnet before Ansible can
# reach it (D10). Signing key pinned by SHA-256, like the Ansible role.
key=/usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${UBUNTU_SERIES}.noarmor.gpg" -o "$key"
printf '%s  %s\n' "$TS_APT_KEY_SHA256" "$key" | sha256sum -c --quiet -
chmod 644 "$key"
echo "deb [signed-by=$key] https://pkgs.tailscale.com/stable/ubuntu ${UBUNTU_SERIES} main" \
  > /etc/apt/sources.list.d/tailscale.list
apt-get update -qq
apt-get install -y -qq tailscale
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

# Static tailscale binaries for the initramfs (Go static build), checked
# against Tailscale's published SHA-256 before anything is extracted.
ts_url="https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz"
curl -fsSL "$ts_url" -o /tmp/tailscale.tgz
ts_sha="$(curl -fsSL "${ts_url}.sha256")"
printf '%s  /tmp/tailscale.tgz\n' "$ts_sha" | sha256sum -c --quiet -
mkdir -p "$TARGET/usr/lib/tailscale-initramfs"
tar -xzf /tmp/tailscale.tgz -C "$TARGET/usr/lib/tailscale-initramfs" \
  --strip-components=1 \
  "tailscale_${TAILSCALE_VERSION}_amd64/tailscaled" \
  "tailscale_${TAILSCALE_VERSION}_amd64/tailscale"

# Boot node credentials/config. NOTE: these are embedded into the initramfs
# image on the UNENCRYPTED /boot partition — the accepted trade-off (see
# docs/architecture.md D2/D10). The credential is a tag:boot-unlock OAuth
# client secret (never expires; revocable in the admin console); the query
# parameters make every node it creates ephemeral + pre-authorized. Read via
# `tailscale up --auth-key=file:...`, so it never appears on argv.
umask 077
mkdir -p "$TARGET/etc/tailscale-boot"
printf '%s?ephemeral=true&preauthorized=true' "$TS_BOOT_OAUTH_SECRET" \
  > "$TARGET/etc/tailscale-boot/authkey"
printf '%s\n' "$BOOT_HOSTNAME" > "$TARGET/etc/tailscale-boot/hostname"
printf '%s\n' "$BOOT_TAG" > "$TARGET/etc/tailscale-boot/tags"

# First-boot tailnet join for the REAL system (D10): a fresh server (first
# deploy, image roll, restore) is otherwise unreachable — the host is dark
# and Ansible connects only over the tailnet. The tag:server OAuth client
# secret sits on the ENCRYPTED root and is deleted after a successful join.
mkdir -p "$TARGET/etc/tailscale-firstboot"
printf '%s?ephemeral=false&preauthorized=true' "$TS_SERVER_OAUTH_SECRET" \
  > "$TARGET/etc/tailscale-firstboot/authkey"
umask 022
cat > "$TARGET/usr/local/sbin/tailscale-firstboot" <<EOF
#!/bin/bash
# Join the tailnet once, on the first boot of a server built from this image,
# so Ansible (tailnet-only) can reach it. Installed by packer/scripts/install-fde.sh.
set -euo pipefail
cred=/etc/tailscale-firstboot/authkey
state="\$(tailscale status --json 2>/dev/null \\
  | python3 -c 'import json, sys; print(json.load(sys.stdin).get("BackendState", ""))' || true)"
if [[ "\$state" != "Running" ]]; then
  tailscale up --auth-key="file:\$cred" --advertise-tags=$SERVER_TAG \\
    --hostname=$SERVER_HOSTNAME --ssh --timeout=60s
fi
rm -f "\$cred"
EOF
chmod 0750 "$TARGET/usr/local/sbin/tailscale-firstboot"
cat > "$TARGET/etc/systemd/system/tailscale-firstboot.service" <<'EOF'
[Unit]
Description=Join the tailnet on the first boot of a fresh server
Wants=network-online.target
After=network-online.target tailscaled.service
Requires=tailscaled.service
# The credential is removed after a successful join: later boots skip this.
ConditionPathExists=/etc/tailscale-firstboot/authkey

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tailscale-firstboot
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

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
# Single-OS server: never probe for other systems. os-prober (pulled in as a
# GRUB Recommends) mounts every partition — the open LUKS root included —
# via grub-mount, a FUSE helper that can outlive the probe and keep
# root_crypt busy at teardown.
echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
# UEFI: EFI/ubuntu plus (by default) the removable fallback path, no NVRAM
# entry. The checks below fail the build if the removable copy is missing.
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=ubuntu --no-nvram
# BIOS fallback, into the bios_grub partition.
grub-install --target=i386-pc /dev/sda
update-grub
for f in /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/BOOT/grubx64.efi /boot/efi/EFI/ubuntu/grub.cfg \
  /boot/grub/i386-pc/core.img /boot/grub/grub.cfg; do
  if [[ ! -s "$f" ]]; then
    echo "ERROR: $f missing — the image would not boot" >&2
    exit 1
  fi
done
update-initramfs -c -k all

# Fail the build, not the first boot: a missing piece of the unlock path would
# otherwise only show up as a server that can't be unlocked remotely.
for initrd in /boot/initrd.img-*; do
  contents="$(lsinitramfs "$initrd")"
  for want in '(^|/)cryptroot/crypttab$' '(^|/)sbin/dropbear$' '/\.ssh/authorized_keys$' \
    '(^|/)usr/bin/tailscaled$' '(^|/)usr/bin/tailscale$' '(^|/)etc/tailscale-boot/authkey$' \
    '(^|/)scripts/init-premount/tailscale$' '(^|/)scripts/init-bottom/tailscale$'; do
    if ! grep -Eq "$want" <<<"$contents"; then
      echo "ERROR: $initrd lacks $want — remote unlock would not work" >&2
      exit 1
    fi
  done
done

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

systemctl enable tailscaled.service tailscale-firstboot.service

# Fresh identity on first boot from the snapshot — including tailscaled's:
# no node state may be baked into the image.
truncate -s 0 /etc/machine-id
rm -rf /var/lib/tailscale/*
passwd -l root
CHROOT

echo "=== 8/8 Teardown"
# Belt-and-braces: ensure no secrets linger outside their intended files.
rm -f "$TARGET/etc/resolv.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"
sync
umount -R "$TARGET/dev" "$TARGET/proc" "$TARGET/sys" "$TARGET/run" || true
umount "$TARGET/boot/efi"
umount "$TARGET/boot"
umount "$TARGET"
# Something may briefly still hold root_crypt (udev probes, an exiting helper).
# Retry; if it stays busy, show who holds it and continue — the filesystem is
# already unmounted and synced, and the rescue system's shutdown before the
# snapshot closes the mapping anyway.
udevadm settle || true
closed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if cryptsetup close "$MAPPER" 2>/dev/null; then
    closed=1
    break
  fi
  sleep 3
done
if [[ "$closed" -eq 0 ]]; then
  echo "WARNING: $MAPPER still in use after unmount; holders follow" >&2
  dm="$(basename "$(readlink -f "/dev/mapper/$MAPPER")")"
  ls -l "/sys/block/$dm/holders" >&2 || true
  dmsetup ls >&2 || true
  devno="$(dmsetup info -c --noheadings -o major,minor "$MAPPER" | tr -d ' ')"
  for mi in /proc/[0-9]*/mountinfo; do
    if grep -q " $devno " "$mi" 2>/dev/null; then
      pid="${mi#/proc/}"
      pid="${pid%/mountinfo}"
      echo "  mounted in the namespace of pid $pid ($(cat "/proc/$pid/comm" 2>/dev/null))" >&2
    fi
  done
  for fd in /proc/[0-9]*/fd/*; do
    if [[ "$(readlink "$fd" 2>/dev/null)" == "/dev/$dm" ]]; then
      pid="${fd#/proc/}"
      pid="${pid%%/*}"
      echo "  held open by pid $pid ($(cat "/proc/$pid/comm" 2>/dev/null))" >&2
    fi
  done
fi
echo "FDE image build complete — Packer will now snapshot."
