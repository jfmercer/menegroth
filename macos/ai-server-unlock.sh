#!/bin/bash
# Mac unlock agent for the AI server's FDE root.
#
# Runs every 30 s via launchd (com.ai-server.unlock.plist). When the server
# reboots, its initramfs joins the tailnet as an ephemeral node tagged
# tag:boot-unlock; this script detects that node, fetches the LUKS
# passphrase from the macOS Keychain, and pipes it over SSH into the forced
# cryptroot-unlock command. The passphrase is never written to disk or
# passed as an argument.
set -euo pipefail

CONFIG="${HOME}/.config/ai-server-unlock/config"
STATE_DIR="${HOME}/.local/state/ai-server-unlock"
mkdir -p "$STATE_DIR"

# Defaults, overridable in $CONFIG.
BOOT_TAG="tag:boot-unlock"
KEYCHAIN_SERVICE="ai-server-luks"
SSH_KEY="${HOME}/.ssh/ai-server-unlock"
NTFY_KEYCHAIN_SERVICE="ai-server-ntfy" # keychain item holding the ntfy topic URL
COOLDOWN_SECONDS=120                   # don't re-attempt within this window
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"

ts_bin() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
  elif [[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
    echo "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  else
    echo "ai-server-unlock: tailscale CLI not found" >&2
    exit 1
  fi
}

notify() { # $1=priority $2=title $3=body — best-effort, never fatal
  local url
  url="$(security find-generic-password -s "$NTFY_KEYCHAIN_SERVICE" -w 2>/dev/null)" || return 0
  curl -fsS -m 10 -H "Priority: $1" -H "Title: $2" -d "$3" "$url" >/dev/null 2>&1 || true
}

# ---- Find an online boot node -------------------------------------------
TS="$(ts_bin)"
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
  # No server waiting at the unlock prompt — normal case; clear first-seen.
  rm -f "$STATE_DIR/first_seen"
  exit 0
fi

# Track when we first saw this boot prompt (used for stuck-at-boot alerting).
[[ -f "$STATE_DIR/first_seen" ]] || date +%s > "$STATE_DIR/first_seen"

# Cooldown: an unlock attempt may take a moment to take effect (node
# disappears after pivot); don't hammer the prompt meanwhile.
now="$(date +%s)"
if [[ -f "$STATE_DIR/last_attempt" ]]; then
  last="$(cat "$STATE_DIR/last_attempt")"
  (( now - last < COOLDOWN_SECONDS )) && exit 0
fi
echo "$now" > "$STATE_DIR/last_attempt"

# ---- Unlock ---------------------------------------------------------------
passphrase="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w)" || {
  notify high "AI server unlock FAILED" "Boot node online but Keychain item '$KEYCHAIN_SERVICE' unreadable."
  exit 1
}

if printf '%s\n' "$passphrase" | ssh \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$STATE_DIR/known_hosts" \
    "root@${boot_ip}" 2>>"$STATE_DIR/unlock.log"; then
  rm -f "$STATE_DIR/first_seen"
  notify default "AI server unlocked" "Root volume unlocked automatically at $(date '+%H:%M:%S'); server is booting."
else
  notify high "AI server unlock FAILED" "SSH unlock attempt to ${boot_ip} failed — see unlock.log. Console fallback: docs/runbooks/break-glass.md."
  exit 1
fi
