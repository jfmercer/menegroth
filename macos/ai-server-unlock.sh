#!/bin/bash
# Mac unlock agent for the AI server's FDE root.
#
# Runs every 30 s via launchd (com.ai-server.unlock.plist). When the server
# reboots, its initramfs joins the tailnet as an ephemeral node tagged
# tag:boot-unlock; this script detects that node, reads the LUKS passphrase
# from 1Password (service account scoped read-only to one dedicated vault),
# and pipes it over SSH into the forced cryptroot-unlock command. The
# passphrase is never written to disk or passed as an argument. 1Password is
# only contacted when a boot node is actually present — the ordinary 30 s
# poll makes zero API calls.
set -euo pipefail

CONFIG="${HOME}/.config/ai-server-unlock/config"
STATE_DIR="${HOME}/.local/state/ai-server-unlock"
mkdir -p "$STATE_DIR"

# Defaults, overridable in $CONFIG.
BOOT_TAG="tag:boot-unlock"
OP_TOKEN_FILE="${HOME}/.config/ai-server-unlock/op-token"
OP_VAULT="Menegroth"
OP_LUKS_REF="op://${OP_VAULT}/luks-passphrase/password"
OP_SSH_KEY_REF="op://${OP_VAULT}/unlock-ssh-key/private key?ssh-format=openssh"
OP_NTFY_REF="op://${OP_VAULT}/ntfy/url"
COOLDOWN_SECONDS=120    # don't re-attempt within this window
STUCK_ALERT_SECONDS=600 # alert if the prompt sits unlocked this long
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
  echo "ai-server-unlock: $name not found" >&2
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

# ---- Find an online boot node ---------------------------------------------
boot_ip="$("$TS" status --json 2>/dev/null | /usr/bin/python3 -c "
import json, sys
try:
    st = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for peer in (st.get('Peer') or {}).values():
    if '${BOOT_TAG}' in (peer.get('Tags') or []) and peer.get('Online'):
        ips = peer.get('TailscaleIPs') or []
        if ips:
            print(ips[0])
            break
")"

if [[ -z "$boot_ip" ]]; then
  # No server waiting at the unlock prompt — normal case; clear incident state.
  rm -f "$STATE_DIR/first_seen" "$STATE_DIR/stuck_alerted"
  exit 0
fi

# A boot node exists — from here on we need 1Password.
OP="$(find_bin op /opt/homebrew/bin/op /usr/local/bin/op)"

# Without the token we can neither unlock nor send an ntfy alert (the ntfy
# URL is itself in the vault) — log loudly so agent.log explains the silence.
if [[ ! -r "$OP_TOKEN_FILE" ]]; then
  echo "ai-server-unlock: server is waiting at the boot prompt but the token file ($OP_TOKEN_FILE) is missing/unreadable — re-run macos/install.sh" >&2
  exit 1
fi

# Track when we first saw this boot prompt (used for stuck-at-boot alerting).
[[ -f "$STATE_DIR/first_seen" ]] || date +%s > "$STATE_DIR/first_seen"

# Stuck-at-boot: the server has been waiting at the unlock prompt for a
# while despite our attempts — escalate once per incident. (The server's own
# healthcheck can't run while its root is locked, so this alert is the only
# signal that a reboot is stuck.)
first_seen="$(cat "$STATE_DIR/first_seen")"
if (( $(date +%s) - first_seen > STUCK_ALERT_SECONDS )) && [[ ! -f "$STATE_DIR/stuck_alerted" ]]; then
  touch "$STATE_DIR/stuck_alerted"
  notify urgent "AI server STUCK at boot" \
    "Boot node online for over $((STUCK_ALERT_SECONDS / 60)) min without a successful unlock. Console fallback: break-glass runbook §0."
fi

# Cooldown: an unlock attempt may take a moment to take effect (node
# disappears after pivot); don't hammer the prompt meanwhile.
now="$(date +%s)"
if [[ -f "$STATE_DIR/last_attempt" ]]; then
  last="$(cat "$STATE_DIR/last_attempt")"
  (( now - last < COOLDOWN_SECONDS )) && exit 0
fi
echo "$now" > "$STATE_DIR/last_attempt"

# ---- Unlock ----------------------------------------------------------------
passphrase="$(op_read "$OP_LUKS_REF")" || {
  notify high "AI server unlock FAILED" \
    "Boot node online but 1Password read failed ($OP_LUKS_REF) — token revoked/expired? See macos/README.md."
  exit 1
}

# The SSH key rests only in 1Password; materialize it for this one ssh call
# in a private tmp dir and remove it on any exit path.
keydir="$(mktemp -d "${TMPDIR:-/tmp}/ai-unlock.XXXXXX")"
chmod 700 "$keydir"
trap 'rm -rf "$keydir"' EXIT
if ! op_read "$OP_SSH_KEY_REF" > "$keydir/id"; then
  notify high "AI server unlock FAILED" "1Password read of the unlock SSH key failed."
  exit 1
fi
chmod 600 "$keydir/id"

if printf '%s\n' "$passphrase" | ssh \
    -i "$keydir/id" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$STATE_DIR/known_hosts" \
    "root@${boot_ip}" 2>>"$STATE_DIR/unlock.log"; then
  rm -f "$STATE_DIR/first_seen" "$STATE_DIR/stuck_alerted"
  notify default "AI server unlocked" "Root volume unlocked automatically at $(date '+%H:%M:%S'); server is booting."
else
  notify high "AI server unlock FAILED" "SSH unlock attempt to ${boot_ip} failed — see unlock.log. Console fallback: docs/runbooks/break-glass.md."
  exit 1
fi
