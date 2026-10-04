#!/usr/bin/env bash
# Image test, on the throwaway server (as root, piped over Tailscale SSH by
# scripts/ci/image-test.sh): is the freshly booted system what the image
# promises? Runs on a server Ansible has never touched, so it uses only what
# the image ships (python3, not jq).
#
# usage: image-test-system.sh <mac-unlock-key-base64-blob> <expected-tailnet-hostname> <ipv6-/64>
set -uo pipefail

mac_blob="$1"
want_hostname="$2"
ipv6_net="$3"
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

# cloud-init renders eth0 from Hetzner's metadata (DHCPv4 + the static IPv6
# /64), and that file, not the image's catch-all fallback, configures the NIC.
network_file="$(networkctl status eth0 2>/dev/null | sed -n 's/^ *Network File: //p')"
if [[ "$network_file" == */10-netplan-eth0.network ]]; then
  pass "eth0 is configured from cloud-init's 10-netplan-eth0.network"
else
  fail "eth0's network file is '${network_file:-none}', want 10-netplan-eth0.network"
fi
want_v6="${ipv6_net%/*}"
want_v6="${want_v6%::}::1"
if ip -6 addr show dev eth0 scope global | grep -q "inet6 $want_v6/64"; then
  pass "eth0 has the server's IPv6 address $want_v6"
else
  fail "eth0 lacks $want_v6/64: $(ip -6 -br addr show dev eth0 scope global)"
fi
if ping -6 -c 1 -W 5 2606:4700:4700::1111 >/dev/null 2>&1; then
  pass "IPv6 egress works"
else
  fail "no IPv6 egress (ping -6 2606:4700:4700::1111)"
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
  # From the start of the boot (monotonic seconds), not the tail: what
  # happened first is what explains a stuck link.
  section "this boot: networkd and wait-online, from the start"
  journalctl -b --no-pager -o short-monotonic -u systemd-networkd -u systemd-networkd-wait-online 2>&1 | head -n 80
  section "this boot: kernel link and address events"
  journalctl -b -k --no-pager -o short-monotonic 2>&1 |
    grep -iE 'eth0|enp|renamed|ADDRCONF|ipv6|virtio_net' | head -n 40
  section "this boot: cloud-init, without the ci-info tables"
  journalctl -b --no-pager -o short-monotonic -u cloud-init-local -u cloud-init-network \
    -u cloud-init-main -u cloud-config 2>&1 | grep -v 'ci-info' | head -n 60
  section "cloud-init log: network steps, warnings, errors"
  grep -E 'WARNING|ERROR|Traceback|[Rr]enam|[Ee]phemeral|dhcp|Applying network|netplan|link set|Bringing|[Ee]vent|update_event|network config' \
    /var/log/cloud-init.log 2>/dev/null | grep -v 'ci-info' | head -n 80
  section "IPv6 sysctls for eth0"
  for k in disable_ipv6 addr_gen_mode accept_ra keep_addr_on_down; do
    printf '%s=%s\n' "$k" "$(cat "/proc/sys/net/ipv6/conf/eth0/$k" 2>/dev/null)"
  done
fi

((fails == 0))
