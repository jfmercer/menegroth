#!/usr/bin/env bash
# Image test, on the throwaway server (as root, piped over Tailscale SSH by
# scripts/ci/image-test.sh): is the freshly booted system what the image
# promises? Runs on a server Ansible has never touched, so it uses only what
# the image ships (python3, not jq).
#
# usage: image-test-system.sh <mac-unlock-key-base64-blob> <expected-tailnet-hostname>
set -uo pipefail

mac_blob="$1"
want_hostname="$2"
fails=0
pass() { printf '    PASS %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*"; fails=$((fails + 1)); }

state="$(timeout 600 systemctl is-system-running --wait 2>/dev/null)"
if [[ "$state" == running ]]; then
  pass "systemd: running, no failed units"
else
  fail "systemd: ${state:-no answer}; failed units: $(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"
fi

if [[ "$(findmnt -no SOURCE /)" == /dev/mapper/root_crypt ]] &&
  cryptsetup status root_crypt | grep -Eq 'type: +LUKS2'; then
  pass "root is mounted from LUKS2 root_crypt"
else
  fail "root is not on LUKS2 root_crypt ($(findmnt -no SOURCE /))"
fi

if [[ ! -e /etc/tailscale-firstboot/authkey ]]; then
  pass "first-boot credential deleted"
else
  fail "/etc/tailscale-firstboot/authkey still exists"
fi

identity="$(tailscale status --json | python3 -c '
import json, sys
me = json.load(sys.stdin)["Self"]
print(me.get("HostName", ""), ",".join(me.get("Tags") or []))')"
if [[ "$identity" == "$want_hostname "*tag:server* ]]; then
  pass "joined the tailnet as $want_hostname with tag:server"
else
  fail "tailnet identity is '$identity', want '$want_hostname' with tag:server"
fi

ts_setup="$(networkctl list --no-legend | awk '$2 == "tailscale0" {print $5}')"
if [[ "$ts_setup" == unmanaged ]]; then
  pass "networkd leaves tailscale0 unmanaged"
else
  fail "networkd manages tailscale0 (setup state: ${ts_setup:-absent})"
fi

netplan_ci=/etc/netplan/50-cloud-init.yaml
if [[ -e "$netplan_ci" ]] && grep -q tailscale0 "$netplan_ci"; then
  fail "$netplan_ci configures tailscale0"
else
  pass "netplan has no tailscale0 entry"
fi

# The test unlocked with its own per-build key, so check the Mac's directly:
# in the dropbear config, and inside the initramfs that boots next.
if grep -qF "$mac_blob" /etc/dropbear/initramfs/authorized_keys; then
  pass "dropbear's authorized_keys holds the Mac unlock key"
else
  fail "the Mac unlock key is missing from /etc/dropbear/initramfs/authorized_keys"
fi

initrd="/boot/initrd.img-$(uname -r)"
contents="$(lsinitramfs "$initrd")"
missing=""
for want in '(^|/)cryptroot/crypttab$' '(^|/)sbin/dropbear$' '/\.ssh/authorized_keys$' \
  '(^|/)usr/bin/tailscaled$' '(^|/)usr/bin/tailscale$' '(^|/)etc/tailscale-boot/authkey$' \
  '(^|/)scripts/init-premount/tailscale$' '(^|/)scripts/init-bottom/tailscale$'; do
  grep -Eq "$want" <<<"$contents" || missing+=" $want"
done
if [[ -z "$missing" ]]; then
  pass "the initramfs carries the unlock path"
else
  fail "$initrd lacks:$missing"
fi

unpacked="$(mktemp -d)"
if unmkinitramfs "$initrd" "$unpacked" && grep -rqF --include=authorized_keys "$mac_blob" "$unpacked"; then
  pass "the initramfs holds the Mac unlock key"
else
  fail "the Mac unlock key is not inside $initrd"
fi
rm -rf "$unpacked"

# The throwaway is deleted when the job ends, so explain a failure while it
# still exists. The repo (and so this log) is public: only network state and
# unit logs from the throwaway, nothing with credentials in it.
if ((fails > 0)); then
  section() { printf '\n---- %s\n' "$1"; }
  section "failed units"
  systemctl --failed --no-legend --plain
  section "links and addresses"
  ip -br link
  ip -br addr
  networkctl list --no-legend
  section "networkd's view of eth0"
  networkctl status eth0 --no-pager 2>&1 | head -40
  section "generated network units (/run/systemd/network, wait-online drop-ins)"
  ls -l /run/systemd/network/ 2>&1
  for f in /run/systemd/system/systemd-networkd-wait-online.service.d/*.conf; do
    [[ -e "$f" ]] && { echo "# $f"; cat "$f"; }
  done
  section "netplan config"
  for f in /etc/netplan/*.yaml /run/netplan/*.yaml; do
    [[ -e "$f" ]] && { echo "# $f"; cat "$f"; }
  done
  section "this boot: networkd, wait-online, udev, cloud-init (monotonic seconds)"
  journalctl -b --no-pager -o short-monotonic \
    -u systemd-networkd -u systemd-networkd-wait-online -u systemd-udevd \
    -u cloud-init-local -u cloud-init-network -u cloud-init-main -u cloud-config -u cloud-final \
    -u tailscaled 2>&1 | tail -n 150
  section "cloud-init warnings and errors"
  grep -E 'WARNING|ERROR|Traceback|[Rr]enam' /var/log/cloud-init.log 2>/dev/null | tail -n 60
fi

((fails == 0))
