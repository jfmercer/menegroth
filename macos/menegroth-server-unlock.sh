#!/bin/bash
# Mac unlock agent for the Menegroth server's FDE root.
#
# Runs every 30 s via launchd (com.menegroth-server.unlock.plist). When the server
# reboots, its initramfs joins the tailnet as an ephemeral node tagged
# tag:boot-unlock; this script detects that node, VERIFIES it is really the
# server (below), reads the LUKS passphrase from 1Password (service account
# scoped read-only to one dedicated vault), and pipes it over SSH into the
# forced cryptroot-unlock command. The passphrase is never written to disk or
# passed as an argument. 1Password is only contacted when a boot node is
# actually present — the ordinary 30 s poll makes zero API calls.
#
# Origin verification (docs/architecture.md D11): the boot node's tailnet
# credential sits on the unencrypted /boot, so anyone with a copy of the disk
# can join as tag:boot-unlock. The tag alone therefore proves nothing. Before
# sending anything, the agent runs `tailscale ping --until-direct` and
# requires the pong to arrive over a DIRECT path from the server's own public
# address (SERVER_IPV4 / SERVER_IPV6_NET in the config). A disco pong is
# authenticated with the peer's key, so only the holder of that node key,
# actually receiving at that address, can produce it. Outcomes:
#   verified   — direct pong from the server's address: unlock.
#   unverified — no direct path (relay only / no reply): SAFE REFUSAL; never
#                unlock, alert after a grace period (docs/troubleshooting.md).
#   mismatch   — direct pong from some OTHER address: possible impersonation;
#                never unlock, urgent alert.
# Fail closed: with no SERVER_IPV4 configured, the agent never unlocks.
#
# usage: menegroth-server-unlock [--diagnose]
#   --diagnose  print what the agent sees and decides; touches no state, no
#               1Password, sends nothing (docs/troubleshooting.md).
set -euo pipefail

DIAGNOSE=false
case "${1:-}" in
  "") ;;
  --diagnose) DIAGNOSE=true ;;
  *) echo "usage: menegroth-server-unlock [--diagnose]" >&2; exit 2 ;;
esac

CONFIG="${HOME}/.config/menegroth-server-unlock/config"
STATE_DIR="${HOME}/.local/state/menegroth-server-unlock"
mkdir -p "$STATE_DIR"

# Defaults, overridable in $CONFIG.
BOOT_TAG="tag:boot-unlock"
OP_TOKEN_FILE="${HOME}/.config/menegroth-server-unlock/op-token"
OP_VAULT="Menegroth"
OP_LUKS_REF="op://${OP_VAULT}/luks-passphrase/password"
OP_SSH_KEY_REF="op://${OP_VAULT}/unlock-ssh-key/private key?ssh-format=openssh"
OP_NTFY_REF="op://${OP_VAULT}/ntfy/url"
COOLDOWN_SECONDS=120      # don't re-attempt within this window
STUCK_ALERT_SECONDS=600   # alert if the prompt sits unlocked this long
VERIFY_GRACE_SECONDS=180  # alert on a safe refusal once it lasts this long
# The server's Hetzner Primary IPs (terraform outputs server_ipv4 /
# server_ipv6_network). Set by macos/install.sh. Empty = never unlock.
SERVER_IPV4=""
SERVER_IPV6_NET=""
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"

find_bin() { # $1=name, remaining args = fallback paths (launchd has a bare PATH)
  local name="$1"
  shift
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return
  fi
  local p
  for p in "$@"; do
    [[ -x "$p" ]] && { echo "$p"; return; }
  done
  echo "menegroth-server-unlock: $name not found" >&2
  return 1
}

TS="$(find_bin tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale)"

op_read() { # $1=secret reference — token comes from the 0600 token file
  OP_SERVICE_ACCOUNT_TOKEN="$(cat "$OP_TOKEN_FILE")" "$OP" read "$1"
}

notify() { # $1=priority $2=title $3=body — best-effort, never fatal
  local url
  url="$(op_read "$OP_NTFY_REF" 2>/dev/null)" || return 0
  curl -fsS -m 10 -H "Priority: $1" -H "Title: $2" -d "$3" "$url" >/dev/null 2>&1 || true
}

# alert_once <state-flag> <priority> <title> <body> — once per boot incident.
alert_once() {
  [[ -f "$STATE_DIR/$1" ]] && return 0
  touch "$STATE_DIR/$1"
  notify "$2" "$3" "$4"
}

# origin_allowed <ip> — is this the server's own public address?
origin_allowed() {
  /usr/bin/python3 - "$1" "$SERVER_IPV4" "$SERVER_IPV6_NET" <<'PY'
import ipaddress
import sys

host, v4, v6 = sys.argv[1:4]
try:
    addr = ipaddress.ip_address(host)
    if addr.version == 4:
        ok = bool(v4) and addr == ipaddress.ip_address(v4)
    else:
        ok = bool(v6) and addr in ipaddress.ip_network(v6, strict=False)
except ValueError:
    ok = False
sys.exit(0 if ok else 1)
PY
}

# check_origin <tailnet-ip> — sets ORIGIN_STATUS (verified|unverified|
# mismatch) and ORIGIN_EP (the observed path) for that boot node.
check_origin() {
  local out ep host
  out="$("$TS" ping --c 5 --timeout 3s --until-direct "$1" 2>&1)" || true
  ep="$(sed -n 's/^pong from .* via \(.*\) in .*$/\1/p' <<<"$out" | tail -n1)"
  case "$ep" in
    "" | DERP\(* | peer-relay\(* | disco | TSMP | ICMP | peerapi)
      ORIGIN_STATUS=unverified
      ORIGIN_EP="${ep:-no reply}"
      return
      ;;
  esac
  ORIGIN_EP="$ep"
  host="${ep%:*}"
  host="${host#[}"
  host="${host%]}"
  if origin_allowed "$host"; then
    ORIGIN_STATUS=verified
  else
    ORIGIN_STATUS=mismatch
  fi
}

clear_incident() {
  rm -f "$STATE_DIR/first_seen" "$STATE_DIR/stuck_alerted" \
    "$STATE_DIR/refusal_alerted" "$STATE_DIR/mismatch_alerted" \
    "$STATE_DIR/unconfigured_alerted"
}

# ---- Find online boot nodes --------------------------------------------------
# Every online tag:boot-unlock peer is a CANDIDATE, one "<tailnet-ip> <name>"
# per line — an impostor and the real server may be online at the same time.
candidates="$("$TS" status --json 2>/dev/null | /usr/bin/python3 -c "
import json, sys
try:
    st = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for peer in (st.get('Peer') or {}).values():
    if '${BOOT_TAG}' in (peer.get('Tags') or []) and peer.get('Online'):
        ips = peer.get('TailscaleIPs') or []
        if ips:
            print(ips[0], peer.get('HostName') or '?')
")"

if $DIAGNOSE; then
  echo "config:     $CONFIG"
  echo "SERVER_IPV4=${SERVER_IPV4:-<unset — agent will NEVER unlock>}"
  echo "SERVER_IPV6_NET=${SERVER_IPV6_NET:-<unset>}"
  if [[ -z "$candidates" ]]; then
    echo "boot nodes: none online (server is not waiting at the unlock prompt)"
    exit 0
  fi
  while read -r ip name; do
    check_origin "$ip"
    [[ -n "$SERVER_IPV4" ]] || ORIGIN_STATUS="unconfigured (never unlocks)"
    echo "boot node:  $name ($ip) via $ORIGIN_EP -> $ORIGIN_STATUS"
  done <<<"$candidates"
  exit 0
fi

if [[ -z "$candidates" ]]; then
  # No server waiting at the unlock prompt — normal case; clear incident state.
  clear_incident
  exit 0
fi

# A boot node exists — from here on we need 1Password.
OP="$(find_bin op /opt/homebrew/bin/op /usr/local/bin/op)"

# Without the token we can neither unlock nor send an ntfy alert (the ntfy
# URL is itself in the vault) — log loudly so agent.log explains the silence.
if [[ ! -r "$OP_TOKEN_FILE" ]]; then
  echo "menegroth-server-unlock: server is waiting at the boot prompt but the token file ($OP_TOKEN_FILE) is missing/unreadable — re-run macos/install.sh" >&2
  exit 1
fi

# Track when we first saw this boot prompt (stuck + refusal alerting).
[[ -f "$STATE_DIR/first_seen" ]] || date +%s > "$STATE_DIR/first_seen"
first_seen="$(cat "$STATE_DIR/first_seen")"
now="$(date +%s)"

# Stuck-at-boot: the server has been waiting at the unlock prompt for a
# while despite our attempts — escalate once per incident. (The server's own
# healthcheck can't run while its root is locked, so this alert is the only
# signal that a reboot is stuck.)
if (( now - first_seen > STUCK_ALERT_SECONDS )); then
  alert_once stuck_alerted urgent "Menegroth server STUCK at boot" \
    "Boot node online for over $((STUCK_ALERT_SECONDS / 60)) min without a successful unlock. See docs/troubleshooting.md."
fi

# Fail closed: without the server's address nothing can be verified.
if [[ -z "$SERVER_IPV4" ]]; then
  echo "menegroth-server-unlock: SERVER_IPV4 not set in $CONFIG — refusing to unlock (re-run macos/install.sh)" >&2
  alert_once unconfigured_alerted high "Menegroth server unlock REFUSED" \
    "The unlock agent has no SERVER_IPV4 configured, so it cannot verify the boot node and will not unlock. Set it via macos/install.sh; meanwhile unlock from the Hetzner console (docs/troubleshooting.md)."
  exit 1
fi

# ---- Verify each candidate's network origin --------------------------------
target=""
unverified=""
while read -r ip name; do
  check_origin "$ip"
  echo "menegroth-server-unlock: boot node $name ($ip) via $ORIGIN_EP -> $ORIGIN_STATUS" >&2
  case "$ORIGIN_STATUS" in
    verified) [[ -n "$target" ]] || target="$ip" ;;
    mismatch)
      alert_once mismatch_alerted urgent "Menegroth server: UNVERIFIED boot node (possible impersonation)" \
        "A tag:boot-unlock node ($name, $ip) answered directly from $ORIGIN_EP, which is NOT the server's address. The passphrase was NOT sent. Unless you are testing a new image, treat this as a security incident: docs/troubleshooting.md."
      ;;
    unverified) unverified="$name ($ip) via $ORIGIN_EP" ;;
  esac
done <<<"$candidates"

if [[ -z "$target" ]]; then
  # Safe refusal: never send the passphrase over a path we could not verify.
  # Paths often go direct within seconds, so retry silently for a grace
  # period before alerting.
  if [[ -n "$unverified" ]] && (( now - first_seen > VERIFY_GRACE_SECONDS )); then
    alert_once refusal_alerted high "Menegroth server unlock REFUSED (could not verify)" \
      "Boot node $unverified has no direct path from this Mac, so its origin cannot be verified and the passphrase was NOT sent. The agent keeps retrying. To unlock now, use the Hetzner console: docs/troubleshooting.md."
  fi
  exit 0
fi

# Cooldown: an unlock attempt may take a moment to take effect (node
# disappears after pivot); don't hammer the prompt meanwhile.
if [[ -f "$STATE_DIR/last_attempt" ]]; then
  last="$(cat "$STATE_DIR/last_attempt")"
  (( now - last < COOLDOWN_SECONDS )) && exit 0
fi
echo "$now" > "$STATE_DIR/last_attempt"

# ---- Unlock ----------------------------------------------------------------
passphrase="$(op_read "$OP_LUKS_REF")" || {
  notify high "Menegroth server unlock FAILED" \
    "Boot node online but 1Password read failed ($OP_LUKS_REF) — token revoked/expired? See macos/README.md."
  exit 1
}

# The SSH key rests only in 1Password; materialize it for this one ssh call
# in a private tmp dir and remove it on any exit path.
keydir="$(mktemp -d "${TMPDIR:-/tmp}/menegroth-server-unlock.XXXXXX")"
chmod 700 "$keydir"
trap 'rm -rf "$keydir"' EXIT
if ! op_read "$OP_SSH_KEY_REF" > "$keydir/id"; then
  notify high "Menegroth server unlock FAILED" "1Password read of the unlock SSH key failed."
  exit 1
fi
chmod 600 "$keydir/id"

# No trailing newline: with stdin not a TTY, cryptroot-unlock passes it to
# cryptsetup byte for byte (cat into askpass's fifo, which strips nothing),
# and the disk was formatted with exactly the passphrase's bytes.
if printf '%s' "$passphrase" | ssh \
    -i "$keydir/id" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$STATE_DIR/known_hosts" \
    "root@${target}" 2>>"$STATE_DIR/unlock.log"; then
  clear_incident
  notify default "Menegroth server unlocked" "Root volume unlocked automatically at $(date '+%H:%M:%S') (origin verified); server is booting."
else
  notify high "Menegroth server unlock FAILED" "SSH unlock attempt to ${target} failed — see $STATE_DIR/unlock.log on the Mac. Console fallback: docs/troubleshooting.md."
  exit 1
fi
