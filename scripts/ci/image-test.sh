#!/usr/bin/env bash
# Image test: boot a throwaway server from a freshly built FDE snapshot,
# unlock it, and prove the image works before Terraform may roll production
# onto it (docs/architecture.md D13). Runs in packer.yml right after the
# build, on a runner that has joined the tailnet as tag:ci.
#
# usage: image-test.sh run       create the throwaway and test it
#        image-test.sh cleanup   delete everything `run` created (idempotent)
#        image-test.sh promote   label the snapshot fde=true (Terraform's selector)
#        image-test.sh discard   delete the snapshot
#
# What `run` proves, in boot order:
#   1. the initramfs joins the tailnet as a tag:boot-unlock node from the
#      throwaway's address, and dropbear answers over the tailnet (the Mac's
#      unlock path);
#   2. dropbear accepts the passphrase and the root volume opens;
#   3. the boot node logs out at pivot, and the first-boot unit joins the
#      real system as menegroth-server (tag:server) and deletes its credential;
#   4. the booted system is healthy: no failed units, root on LUKS2, network
#      state as designed (eth0 from Hetzner's metadata, with the server's
#      IPv6 address and working IPv6), and the MAC's unlock key is in the
#      initramfs (the test unlocks with its own per-build key, so this is
#      checked directly);
#   5. kernel-update survival: reinstalling the kernel rebuilds the initramfs
#      with the unlock path, and the server unlocks and rejoins after a reboot.
# Not covered: unlocking at the Hetzner web console (stock Ubuntu cryptsetup;
# there is no API to type into the console).
#
# Where the production passphrase goes: over SSH to the throwaway's public
# IPv4, the address Hetzner just assigned it, never to a tailnet node. That
# trusts what the Mac's D11 check trusts (whoever answers at the server's
# own address is the server) without needing a direct tailscale path, which
# GitHub runners don't reliably get. The throwaway's firewall admits SSH from
# this runner's address only. The Mac agent also sees the throwaway's boot
# node, from the wrong address; it refuses, and alerts only if that lasts
# longer than its grace period (VERIFY_GRACE_SECONDS).
set -euo pipefail

: "${HCLOUD_TOKEN:?}"
STATE_FILE="${IMAGE_TEST_STATE:-${RUNNER_TEMP:-/tmp}/image-test.state}"
WORK="${STATE_FILE%/*}"
RUN="${GITHUB_RUN_ID:-local}"
NAME="menegroth-image-test-$RUN"
PURPOSE=menegroth-image-test        # label on everything this script creates
SERVER_TYPE=cpx22                   # the build type: the snapshot fits it exactly
LOCATION=nbg1
ADMIN_USER="admin"
SERVER_HOSTNAME=menegroth-server
BOOT_TAG=tag:boot-unlock
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

# ---- Reaching the throwaway ---------------------------------------------------
# banner <host> — the SSH server's identification line ("SSH-2.0-dropbear_…"
# at the unlock prompt, "SSH-2.0-OpenSSH_…" once booted), or nothing.
banner() {
  # shellcheck disable=SC2016 # expanded by the inner bash
  timeout 8 bash -c 'exec 3<>"/dev/tcp/$1/22" && head -n1 <&3' _ "$1" 2>/dev/null | tr -d '\r'
}

# wait_banner <host> <dropbear|OpenSSH|down> <timeout-seconds>
wait_banner() {
  local deadline=$((SECONDS + $3)) got
  while ((SECONDS < deadline)); do
    got="$(banner "$1")"
    case "$2" in
      down) [[ "$got" != *OpenSSH* ]] && return 0 ;;
      *) [[ "$got" == *"$2"* ]] && return 0 ;;
    esac
    sleep 5
  done
  return 1
}

# boot_node — the control plane's record of the throwaway's boot node: a
# connected tag:boot-unlock device reporting an endpoint at the throwaway's
# address. Only used to check the tailnet join, never to decide where the
# passphrase goes.
boot_node() {
  "$HERE/tailnet-devices.sh" list 2>/dev/null | jq -c --arg t "$BOOT_TAG" --arg v4 "$TEST_IPV4" \
    '[.[] | select(((.tags // []) | index($t)) and .connectedToControl
       and (((.clientConnectivity.endpoints // []) | map(sub(":[0-9]+$"; ""))) | index($v4)))] | first // empty'
}

# ssh_opts — no host-key pinning: the destination is the address Hetzner
# assigned, which is the trust anchor (see the header).
SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15
  -o ServerAliveInterval=10 -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# unlock — send the passphrase to dropbear's forced cryptroot-unlock, without
# a trailing newline (macos/menegroth-server-unlock.sh explains why).
unlock() {
  printf '%s' "$ROOT_LUKS_KEY" | ssh "${SSH_OPTS[@]}" -i "$TEST_UNLOCK_KEY" "root@$TEST_IPV4" >&2
}

# on_server <bash-args...> — run a script from stdin as root on the booted
# throwaway, as admin with the bootstrap key its cloud-init authorized.
on_server() {
  ssh "${SSH_OPTS[@]}" -i "$ADMIN_KEY" "$ADMIN_USER@$TEST_IPV4" sudo bash -s -- "$@"
}

# Unlock one boot of the throwaway and wait until its real system is up.
boot_and_unlock() { # boot_and_unlock <label>
  local node ts_ip deadline
  log "$1: waiting for dropbear at $TEST_IPV4"
  wait_banner "$TEST_IPV4" dropbear 420 ||
    die "$1: dropbear never answered on $TEST_IPV4:22 within 7 minutes (did the server boot? is $RUNNER_IPV4 still this runner's address?)"
  pass "dropbear is up at the unlock prompt"

  # The Mac's path: the boot node joins the tailnet and dropbear answers
  # over it. A relayed path is fine here; nothing secret travels over it.
  deadline=$((SECONDS + 240))
  until node="$(boot_node)" && [[ -n "$node" ]]; do
    ((SECONDS < deadline)) || {
      echo "  tag:boot-unlock devices the control plane knows:" >&2
      "$HERE/tailnet-devices.sh" list 2>/dev/null | jq -r --arg t "$BOOT_TAG" '.[] | select((.tags // []) | index($t))
        | "    \(.name) connected=\(.connectedToControl) endpoints=\(.clientConnectivity.endpoints // [] | join(","))"' >&2 || true
      die "$1: no boot node joined the tailnet from $TEST_IPV4 within 4 minutes (initramfs logs: /run/initramfs/tailscale-up.log)"
    }
    sleep 10
  done
  ts_ip="$(jq -r '.addresses[0]' <<<"$node")"
  pass "the boot node joined the tailnet ($(jq -r .name <<<"$node"), $ts_ip)"
  deadline=$((SECONDS + 120))
  until [[ "$(banner "$ts_ip")" == *dropbear* ]]; do
    ((SECONDS < deadline)) || die "$1: dropbear does not answer over the tailnet at $ts_ip:22 (the ACL needs tag:ci -> tag:boot-unlock:22, D4)"
    sleep 5
  done
  pass "dropbear answers over the tailnet, the Mac agent's path"

  log "$1: sending the passphrase to $TEST_IPV4 (the throwaway's assigned address)"
  unlock || die "$1: the unlock SSH session failed"
  pass "cryptroot-unlock accepted the passphrase"

  deadline=$((SECONDS + 180))
  while node="$(boot_node)" && [[ -n "$node" ]]; do
    ((SECONDS < deadline)) || die "$1: the boot node stayed on the tailnet after the unlock (it should log out at pivot)"
    sleep 5
  done
  pass "the boot node left the tailnet at pivot"

  log "$1: waiting for the real system"
  wait_banner "$TEST_IPV4" OpenSSH 420 || die "$1: the real system's sshd never answered within 7 minutes"
  deadline=$((SECONDS + 300))
  until on_server <<<'true' 2>/dev/null; do # cloud-init creates the admin user
    ((SECONDS < deadline)) || die "$1: cannot log in as $ADMIN_USER on $TEST_IPV4"
    sleep 10
  done
  pass "the real system is up and reachable"
}

cmd_run() {
  : "${SNAPSHOT_ID:?}" "${ROOT_LUKS_KEY:?}" "${TEST_UNLOCK_KEY:?}" "${SSH_PRIVATE_KEY:?}"
  : "${MAC_UNLOCK_SSH_PUBKEY:?}" "${ADMIN_SSH_PUBLIC_KEY:?}"
  : >"$STATE_FILE"

  # The bootstrap admin key (/ci/SSH_PRIVATE_KEY): its public half is what
  # production's cloud-init authorizes, so the throwaway accepts it too.
  ADMIN_KEY="$WORK/image-test-admin-key"
  (umask 077 && printf '%s\n' "$SSH_PRIVATE_KEY" >"$ADMIN_KEY")

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
  local key_id fp fw_id user_data body server netcheck
  fp="$(ssh-keygen -l -E md5 -f - <<<"$ADMIN_SSH_PUBLIC_KEY" | awk '{print $2}')"
  fp="${fp#MD5:}"
  key_id="$(hc GET "/ssh_keys?fingerprint=$fp" | jq -r '.ssh_keys[0].id // empty')"
  if [[ -z "$key_id" ]]; then
    key_id="$(hc POST /ssh_keys "$(jq -nc --arg n "$NAME" --arg k "$ADMIN_SSH_PUBLIC_KEY" \
      --arg p "$PURPOSE" --arg r "$RUN" '{name: $n, public_key: $k, labels: {purpose: $p, run: $r}}')" |
      jq -r .ssh_key.id)"
    save SSH_KEY_ID "$key_id"
  fi

  # SSH from this runner only. Its public address, as tailscale's STUN
  # probes see it.
  netcheck="$(tailscale netcheck --format=json 2>/dev/null)"
  RUNNER_IPV4="$(jq -r '.GlobalV4 // empty' <<<"$netcheck")"
  RUNNER_IPV4="${RUNNER_IPV4%:*}"
  [[ -n "$RUNNER_IPV4" ]] || die "could not determine this runner's public IPv4 (tailscale netcheck)"
  log "Runner $RUNNER_IPV4 (NAT mapping varies by destination: $(jq -r .MappingVariesByDestIP <<<"$netcheck"))"

  log "Creating the throwaway's firewall and server ($SERVER_TYPE, $LOCATION)"
  fw_id="$(hc POST /firewalls "$(jq -nc --arg n "$NAME" --arg p "$PURPOSE" --arg r "$RUN" --arg src "$RUNNER_IPV4/32" '{
    name: $n, labels: {purpose: $p, run: $r},
    rules: [{direction: "in", protocol: "tcp", port: "22", source_ips: [$src],
             description: "SSH from the image-test runner only"}]}')" | jq -r .firewall.id)"
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

  local mac_blob
  mac_blob="$(awk '{print $2}' <<<"$MAC_UNLOCK_SSH_PUBKEY")"

  # ---- First boot -----------------------------------------------------------
  boot_and_unlock "first boot"
  # Recorded first, so cleanup can remove this exact node whatever happens next.
  SERVER_NODE_ID="$(on_server <<<"timeout 300 systemctl is-system-running --wait >/dev/null; tailscale status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)[\"Self\"][\"ID\"])'")"
  save SERVER_NODE_ID "$SERVER_NODE_ID"
  log "first boot: checking the booted system"
  on_server "$mac_blob" "$SERVER_HOSTNAME" "$TEST_IPV6_NET" <"$HERE/image-test-system.sh" >&2 || die "first boot: system checks failed"

  # ---- Kernel-update survival ------------------------------------------------
  log "kernel update: reinstalling the kernel to rebuild the initramfs"
  on_server <"$HERE/image-test-kernel.sh" >&2 || die "kernel update: the initramfs rebuild failed"
  log "kernel update: rebooting"
  # The shutdown often kills sshd before the client exits, which ssh reports
  # as a failure; whether the server actually went down is checked next.
  on_server <<<'systemctl --no-block reboot' >/dev/null 2>&1 || true
  wait_banner "$TEST_IPV4" down 180 || die "kernel update: the server did not go down for the reboot"
  boot_and_unlock "after the kernel update"
  log "after the kernel update: checking the booted system"
  on_server "$mac_blob" "$SERVER_HOSTNAME" "$TEST_IPV6_NET" <"$HERE/image-test-system.sh" >&2 || die "after the kernel update: system checks failed"

  log "Image test passed"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### Image test passed"
      echo "Snapshot \`$SNAPSHOT_ID\` booted, joined the tailnet at the unlock prompt, unlocked,"
      echo "joined as \`$SERVER_HOSTNAME\`, and survived a kernel reinstall + reboot."
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

# Best effort throughout: one failed deletion must never stop the others.
cmd_cleanup() {
  load
  rm -f "$WORK/image-test-admin-key"
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
