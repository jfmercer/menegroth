#!/usr/bin/env bash
# Image test: boot a throwaway server from a freshly built FDE snapshot,
# unlock it the way the Mac agent does, and prove the image works before
# Terraform may roll production onto it (docs/architecture.md D13). Runs in
# packer.yml right after the build, on a runner that has joined the tailnet
# as tag:ci.
#
# usage: image-test.sh run       create the throwaway and test it
#        image-test.sh cleanup   delete everything `run` created (idempotent)
#        image-test.sh promote   label the snapshot fde=true (Terraform's selector)
#        image-test.sh discard   delete the snapshot
#
# What `run` proves, in boot order:
#   1. the initramfs joins the tailnet as a tag:boot-unlock node;
#   2. that node answers over a DIRECT path from the throwaway's own public
#      address (D11): only then is the passphrase sent, over dropbear;
#   3. the boot node logs out at pivot, and the first-boot unit joins the
#      real system as menegroth-server (tag:server) and deletes its credential;
#   4. the booted system is healthy: no failed units, root on LUKS2, network
#      state as designed, and the MAC's unlock key is in the initramfs (the
#      test unlocks with its own per-build key, so this is checked directly);
#   5. kernel-update survival: reinstalling the kernel rebuilds the initramfs
#      with the unlock path, and the server unlocks and rejoins after a reboot.
# Not covered: unlocking at the Hetzner web console (stock Ubuntu cryptsetup;
# there is no API to type into the console).
#
# The production passphrase is sent only to a node whose origin is verified,
# exactly as the Mac agent does. The Mac agent also sees the throwaway's boot
# node, answering from the wrong address; it refuses, and alerts only if that
# lasts longer than its grace period (VERIFY_GRACE_SECONDS).
set -euo pipefail

: "${HCLOUD_TOKEN:?}"
STATE_FILE="${IMAGE_TEST_STATE:-${RUNNER_TEMP:-/tmp}/image-test.state}"
RUN="${GITHUB_RUN_ID:-local}"
NAME="menegroth-image-test-$RUN"
PURPOSE=menegroth-image-test        # label on everything this script creates
SERVER_TYPE=cpx22                   # the build type: the snapshot fits it exactly
LOCATION=nbg1
ADMIN_USER="admin"
SERVER_HOSTNAME=menegroth-server
BOOT_TAG=tag:boot-unlock
SERVER_TAG=tag:server
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# shellcheck source=scripts/ci/hcloud.sh
source "$HERE/hcloud.sh"

log() { printf '==> %s\n' "$*" >&2; }
pass() { printf '    PASS %s\n' "$*" >&2; }
die() { printf '::error::image test: %s\n' "$*" >&2; exit 1; }

save() { printf '%s=%q\n' "$1" "$2" >>"$STATE_FILE"; }
load() {
  # shellcheck source=/dev/null # written by save() above
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
  return 0
}

# wait_action <action-id> — until a Hetzner action finishes.
wait_action() {
  local status
  for _ in $(seq 1 60); do
    status="$(hc GET "/actions/$1" | jq -r .action.status)"
    case "$status" in
      success) return 0 ;;
      error) return 1 ;;
    esac
    sleep 5
  done
  return 1
}

# ---- Origin check: the Mac agent's D11 logic, from the runner -------------
# in_origin <ip> — is this address the throwaway's IPv4 or in its IPv6 /64?
in_origin() {
  python3 - "$1" "$TEST_IPV4" "$TEST_IPV6_NET" <<'PY'
import ipaddress
import sys

host, v4, v6 = sys.argv[1:4]
try:
    addr = ipaddress.ip_address(host)
    ok = addr == ipaddress.ip_address(v4) if addr.version == 4 else addr in ipaddress.ip_network(v6, strict=False)
except ValueError:
    ok = False
sys.exit(0 if ok else 1)
PY
}

# direct_endpoint <tailnet-ip> — the address a direct pong came from, or
# nothing for a relayed/missing reply (relay = unverifiable, never trusted).
direct_endpoint() {
  local out ep
  out="$(tailscale ping --c 10 --timeout 3s --until-direct "$1" 2>&1)" || true
  ep="$(sed -n 's/^pong from .* via \(.*\) in .*$/\1/p' <<<"$out" | tail -n1)"
  case "$ep" in
    "" | DERP\(* | peer-relay\(* | disco | TSMP | ICMP | peerapi) return 0 ;;
  esac
  ep="${ep%:*}"
  ep="${ep#[}"
  printf '%s' "${ep%]}"
}

# online_peers <tag> — tailnet IPs of online peers carrying the tag.
online_peers() {
  tailscale status --json | jq -r --arg t "$1" \
    '.Peer // {} | .[] | select(.Online and ((.Tags // []) | index($t))) | .TailscaleIPs[0]'
}

# find_node <tag> <timeout-seconds> — the tailnet IP of the online <tag> peer
# that answers DIRECTLY from the throwaway's own address. Other nodes with
# the same tag (production) answer from elsewhere and are skipped.
# Logs each candidate's state whenever it changes, so a timeout shows what
# the runner saw.
find_node() {
  local deadline=$((SECONDS + $2)) ip ep seen="" state
  while ((SECONDS < deadline)); do
    while read -r ip; do
      [[ -n "$ip" ]] || continue
      ep="$(direct_endpoint "$ip")"
      if [[ -n "$ep" ]] && in_origin "$ep"; then
        pass "$1 node $ip answers directly from the throwaway ($ep)"
        printf '%s' "$ip"
        return 0
      fi
      state="$ip:${ep:-relay}"
      if [[ " $seen " != *" $state "* ]]; then
        seen+=" $state"
        if [[ -n "$ep" ]]; then
          echo "    $1 node $ip answers directly from $ep: not the throwaway, skipped" >&2
        else
          echo "    $1 node $ip is online but has no direct path yet (relayed or no reply); retrying" >&2
        fi
      fi
    done < <(online_peers "$1")
    sleep 10
  done
  return 1
}

# show_tailnet <tag> — what the control plane knows about <tag> devices, for
# a timeout: did the node join at all, and from where?
show_tailnet() {
  echo "  The control plane's view of $1 devices:" >&2
  "$HERE/tailnet-devices.sh" list 2>/dev/null | jq -r --arg t "$1" '.[]? | select((.tags // []) | index($t))
    | "    \(.name) connected=\(.connectedToControl) lastSeen=\(.lastSeen) endpoints=\(.clientConnectivity.endpoints // [] | join(","))"' >&2 ||
    echo "    (could not list devices)" >&2
  echo "  The runner's view: $(tailscale status --json | jq -c --arg t "$1" '[.Peer // {} | .[] | select((.Tags // []) | index($t)) | {HostName, Online, CurAddr, Relay}]')" >&2
}

# wait_gone <tailnet-ip> <timeout-seconds> — until no online peer has the IP.
wait_gone() {
  local deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    tailscale status --json | jq -e --arg ip "$1" \
      '[.Peer // {} | .[] | select(.Online and ((.TailscaleIPs // []) | index($ip)))] | length == 0' \
      >/dev/null && return 0
    sleep 5
  done
  return 1
}

# unlock <boot-node-ip> — send the passphrase to the forced cryptroot-unlock,
# without a trailing newline (macos/menegroth-server-unlock.sh explains why).
unlock() {
  printf '%s' "$ROOT_LUKS_KEY" | ssh \
    -i "$TEST_UNLOCK_KEY" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${STATE_FILE%/*}/image-test.known_hosts" \
    "root@$1" >&2
}

# on_server <tailnet-ip> <bash-args...> — run a script from stdin as root over
# Tailscale SSH (tag:ci may log in as admin; the ACL vouches for the host).
on_server() {
  local ip="$1"
  shift
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$ADMIN_USER@$ip" sudo bash -s -- "$@"
}

# Unlock one boot of the throwaway, then wait for its real system.
boot_and_unlock() { # boot_and_unlock <label> -> prints the server's tailnet IP
  local boot_ip server_ip
  log "$1: waiting for the throwaway's boot node (tag:boot-unlock)"
  boot_ip="$(find_node "$BOOT_TAG" 420)" || {
    echo "No $BOOT_TAG node answered directly from $TEST_IPV4 within 7 minutes." >&2
    show_tailnet "$BOOT_TAG"
    echo "  If 'menegroth-server-boot' shows in the admin console, the tailnet ACL lacks" >&2
    echo "  {src: tag:ci, dst: tag:boot-unlock:22} (docs/architecture.md D4)." >&2
    echo "  Otherwise the initramfs never joined: its logs are on the throwaway at" >&2
    echo "  /run/initramfs/tailscale-up.log (console only, it is locked)." >&2
    die "$1: boot node not found"
  }
  log "$1: origin verified; sending the passphrase over dropbear"
  unlock "$boot_ip" || die "$1: the unlock SSH session failed"
  pass "cryptroot-unlock accepted the passphrase"
  wait_gone "$boot_ip" 180 || die "$1: the boot node stayed online after the unlock (it should log out at pivot)"
  pass "the boot node left the tailnet at pivot"
  log "$1: waiting for the real system (tag:server)"
  server_ip="$(find_node "$SERVER_TAG" 420)" || {
    show_tailnet "$SERVER_TAG"
    die "$1: no $SERVER_TAG node from the throwaway within 7 minutes"
  }
  printf '%s' "$server_ip"
}

cmd_run() {
  : "${SNAPSHOT_ID:?}" "${ROOT_LUKS_KEY:?}" "${TEST_UNLOCK_KEY:?}"
  : "${MAC_UNLOCK_SSH_PUBKEY:?}" "${ADMIN_SSH_PUBLIC_KEY:?}"
  : >"$STATE_FILE"

  log "Sweeping image-test leftovers older than 3 hours"
  local cutoff
  cutoff=$(($(date +%s) - 3 * 3600))
  hc GET "/servers?label_selector=purpose%3D$PURPOSE" | jq -r --argjson c "$cutoff" \
    '.servers[] | select((.created[0:19] + "Z" | fromdateiso8601) < $c) | .id' |
    while read -r id; do hc DELETE "/servers/$id" >/dev/null && echo "    deleted stale server $id" >&2 || true; done
  hc GET "/firewalls?label_selector=purpose%3D$PURPOSE" | jq -r --argjson c "$cutoff" \
    '.firewalls[] | select((.created[0:19] + "Z" | fromdateiso8601) < $c) | .id' |
    while read -r id; do hc DELETE "/firewalls/$id" >/dev/null 2>&1 && echo "    deleted stale firewall $id" >&2 || true; done
  hc GET "/ssh_keys?label_selector=purpose%3D$PURPOSE" | jq -r --argjson c "$cutoff" \
    '.ssh_keys[] | select((.created[0:19] + "Z" | fromdateiso8601) < $c) | .id' |
    while read -r id; do hc DELETE "/ssh_keys/$id" >/dev/null && echo "    deleted stale SSH key $id" >&2 || true; done

  # The admin key, as on production: Terraform's hcloud_ssh_key if it exists
  # (Hetzner keys are unique by fingerprint), else a temporary one, e.g. on
  # the very first build, before Terraform has run. Without any key Hetzner
  # would email a root password for the server.
  local key_id fp fw_id user_data body server
  fp="$(ssh-keygen -l -E md5 -f - <<<"$ADMIN_SSH_PUBLIC_KEY" | awk '{print $2}')"
  fp="${fp#MD5:}"
  key_id="$(hc GET "/ssh_keys?fingerprint=$fp" | jq -r '.ssh_keys[0].id // empty')"
  if [[ -z "$key_id" ]]; then
    key_id="$(hc POST /ssh_keys "$(jq -nc --arg n "$NAME" --arg k "$ADMIN_SSH_PUBLIC_KEY" \
      --arg p "$PURPOSE" --arg r "$RUN" '{name: $n, public_key: $k, labels: {purpose: $p, run: $r}}')" |
      jq -r .ssh_key.id)"
    save SSH_KEY_ID "$key_id"
  fi

  # Inbound UDP only: lets tailscale form direct paths to the throwaway, so
  # its origin can be verified from a runner behind NAT. Nothing else in.
  log "Creating the throwaway's firewall and server ($SERVER_TYPE, $LOCATION)"
  fw_id="$(hc POST /firewalls "$(jq -nc --arg n "$NAME" --arg p "$PURPOSE" --arg r "$RUN" '{
    name: $n, labels: {purpose: $p, run: $r},
    rules: [{direction: "in", protocol: "udp", port: "1-65535",
             source_ips: ["0.0.0.0/0", "::/0"],
             description: "tailscale direct paths to the image-test server"}]}')" | jq -r .firewall.id)"
  save FIREWALL_ID "$fw_id"

  # The server gets production's cloud-init, rendered as Terraform would.
  # The single-quoted patterns are Terraform's literal placeholders.
  user_data="$(<"$REPO/terraform/templates/cloud-init.yaml.tftpl")"
  # shellcheck disable=SC2016
  user_data="${user_data//'${admin_user}'/"$ADMIN_USER"}"
  # shellcheck disable=SC2016
  user_data="${user_data//'${admin_ssh_public_key}'/"$ADMIN_SSH_PUBLIC_KEY"}"
  if grep -Eq '[$%]\{' <<<"$user_data"; then
    die "terraform/templates/cloud-init.yaml.tftpl uses template syntax this script does not render; update image-test.sh"
  fi

  body="$(jq -nc --arg n "$NAME" --arg t "$SERVER_TYPE" --arg l "$LOCATION" \
    --arg img "$SNAPSHOT_ID" --argjson key "$key_id" --argjson fw "$fw_id" \
    --arg ud "$user_data" --arg p "$PURPOSE" --arg r "$RUN" '{
      name: $n, server_type: $t, location: $l, image: $img,
      ssh_keys: [$key], firewalls: [{firewall: $fw}], user_data: $ud,
      labels: {purpose: $p, run: $r},
      public_net: {enable_ipv4: true, enable_ipv6: true}}')"
  server="$(hc POST /servers "$body")"
  SERVER_ID="$(jq -r .server.id <<<"$server")"
  TEST_IPV4="$(jq -r .server.public_net.ipv4.ip <<<"$server")"
  TEST_IPV6_NET="$(jq -r .server.public_net.ipv6.ip <<<"$server")"
  save SERVER_ID "$SERVER_ID"
  save TEST_IPV4 "$TEST_IPV4"
  save TEST_IPV6_NET "$TEST_IPV6_NET"
  log "Throwaway $SERVER_ID: $TEST_IPV4, $TEST_IPV6_NET"

  local mac_blob ip
  mac_blob="$(awk '{print $2}' <<<"$MAC_UNLOCK_SSH_PUBKEY")"

  # ---- First boot -----------------------------------------------------------
  ip="$(boot_and_unlock "first boot")"
  # Recorded first, so cleanup can remove this exact node whatever happens next.
  SERVER_NODE_ID="$(on_server "$ip" <<<"tailscale status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)[\"Self\"][\"ID\"])'")"
  save SERVER_NODE_ID "$SERVER_NODE_ID"
  log "first boot: checking the booted system"
  on_server "$ip" "$mac_blob" "$SERVER_HOSTNAME" <"$HERE/image-test-system.sh" >&2 || die "first boot: system checks failed"

  # ---- Kernel-update survival ------------------------------------------------
  log "kernel update: reinstalling the kernel to rebuild the initramfs"
  on_server "$ip" <"$HERE/image-test-kernel.sh" >&2 || die "kernel update: the initramfs rebuild failed"
  log "kernel update: rebooting"
  on_server "$ip" <<<'systemctl --no-block reboot' >&2 || die "kernel update: could not reboot the throwaway"
  wait_gone "$ip" 180 || die "kernel update: the server did not go down for the reboot"
  ip="$(boot_and_unlock "after the kernel update")"
  log "after the kernel update: checking the booted system"
  on_server "$ip" "$mac_blob" "$SERVER_HOSTNAME" <"$HERE/image-test-system.sh" >&2 || die "after the kernel update: system checks failed"

  log "Image test passed"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### Image test passed"
      echo "Snapshot \`$SNAPSHOT_ID\` booted, unlocked over the tailnet with a verified origin,"
      echo "joined as \`$SERVER_HOSTNAME\`, and survived a kernel reinstall + reboot."
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

# Best effort throughout: one failed deletion must never stop the others.
cmd_cleanup() {
  load
  [[ -n "${SERVER_ID:-}" ]] || { log "Nothing to clean up"; return 0; }

  # The throwaway's tailnet nodes. Delete by the node ID the server itself
  # reported, or by its public address, so production's node (same hostname,
  # same tag, different address) can never match.
  local devices id
  if devices="$("$HERE/tailnet-devices.sh" list)"; then
    while read -r id; do
      [[ -z "$id" ]] || "$HERE/tailnet-devices.sh" delete "$id" ||
        echo "::warning::could not remove tailnet node $id; remove it in the admin console"
    done < <(jq -r --arg node "${SERVER_NODE_ID:-}" --arg v4 "${TEST_IPV4:-}" '.[]
      | select(.nodeId == $node or (((.clientConnectivity.endpoints // []) | map(sub(":[0-9]+$"; ""))) | index($v4)))
      | .nodeId' <<<"$devices")
  else
    echo "::warning::could not list tailnet devices; remove the image-test node (a menegroth-server-N) in the admin console"
  fi

  local action
  if action="$(hc DELETE "/servers/$SERVER_ID" | jq -r .action.id)"; then
    wait_action "$action" || echo "::warning::deleting server $SERVER_ID did not finish; check the Hetzner console"
    echo "    deleted server $SERVER_ID" >&2
  fi
  if [[ -n "${SSH_KEY_ID:-}" ]]; then
    hc DELETE "/ssh_keys/$SSH_KEY_ID" >/dev/null && echo "    deleted temporary SSH key $SSH_KEY_ID" >&2
  fi
  if [[ -n "${FIREWALL_ID:-}" ]]; then
    local _
    for _ in $(seq 1 12); do # detaching from the deleted server takes a moment
      hc DELETE "/firewalls/$FIREWALL_ID" >/dev/null 2>&1 && { echo "    deleted firewall $FIREWALL_ID" >&2; break; }
      sleep 5
    done
  fi
  return 0
}

cmd_promote() {
  : "${SNAPSHOT_ID:?}"
  local labels
  labels="$(hc GET "/images/$SNAPSHOT_ID" | jq -c '.image.labels + {fde: "true"}')"
  hc PUT "/images/$SNAPSHOT_ID" "$(jq -nc --argjson l "$labels" '{labels: $l}')" >/dev/null
  log "Snapshot $SNAPSHOT_ID promoted: fde=true, the next replace_server roll uses it"
}

cmd_discard() {
  : "${SNAPSHOT_ID:?}"
  hc DELETE "/images/$SNAPSHOT_ID" >/dev/null
  log "Snapshot $SNAPSHOT_ID deleted (only tested master builds are kept)"
}

case "${1:-}" in
  run) cmd_run ;;
  cleanup) cmd_cleanup ;;
  promote) cmd_promote ;;
  discard) cmd_discard ;;
  *) echo "usage: image-test.sh run | cleanup | promote | discard" >&2; exit 2 ;;
esac
