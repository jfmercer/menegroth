#!/usr/bin/env bash
# Image test, on the throwaway server (as root, piped over Tailscale SSH by
# scripts/ci/image-test.sh): the first half of the kernel-update survival
# test. Reinstalling the running kernel rebuilds its initramfs through the
# same postinst hooks a kernel update runs; the rebuilt image must still
# carry the unlock path. image-test.sh then reboots and unlocks it.
set -euo pipefail

kver="$(uname -r)"
initrd="/boot/initrd.img-$kver"
before="$(stat -c %Y "$initrd")"
sleep 1 # make sure a rebuild gets a newer mtime

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
if apt-get install -y -qq --reinstall "linux-image-$kver" >/dev/null; then
  echo "    reinstalled linux-image-$kver"
else
  # Only when the archive no longer carries this exact kernel build.
  echo "    linux-image-$kver is no longer downloadable; rebuilding with update-initramfs"
  update-initramfs -u -k "$kver"
fi

if (($(stat -c %Y "$initrd") <= before)); then
  echo "    FAIL $initrd was not rebuilt"
  exit 1
fi
contents="$(lsinitramfs "$initrd")"
for want in '(^|/)usr/bin/tailscaled$' '(^|/)usr/bin/tailscale$' '(^|/)etc/tailscale-boot/authkey$' \
  '(^|/)scripts/init-premount/tailscale$' '(^|/)scripts/init-bottom/tailscale$' '(^|/)sbin/dropbear$'; do
  if ! grep -Eq "$want" <<<"$contents"; then
    echo "    FAIL the rebuilt initramfs lacks $want"
    exit 1
  fi
done
echo "    PASS the rebuilt initramfs still carries the unlock path"
