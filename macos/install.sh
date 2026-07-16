#!/bin/bash
# Install the AI server unlock agent on this Mac. Idempotent; re-run after
# editing ai-server-unlock.sh to update the installed copy.
set -euo pipefail
cd "$(dirname "$0")"

BIN="${HOME}/.local/bin/ai-server-unlock"
PLIST_DEST="${HOME}/Library/LaunchAgents/com.ai-server.unlock.plist"
SSH_KEY="${HOME}/.ssh/ai-server-unlock"

echo "==> Installing unlock script to $BIN"
mkdir -p "${HOME}/.local/bin" "${HOME}/.local/state/ai-server-unlock" \
  "${HOME}/.config/ai-server-unlock"
install -m 0700 ai-server-unlock.sh "$BIN"

if [[ ! -f "$SSH_KEY" ]]; then
  echo "==> Generating unlock SSH key ($SSH_KEY)"
  # No passphrase: launchd must use it unattended. FileVault protects it at
  # rest; the key can only run the forced cryptroot-unlock command anyway.
  ssh-keygen -t ed25519 -N "" -C "mac-unlock-agent" -f "$SSH_KEY"
  echo "    Put this PUBLIC key into packer/fde-image.pkr.hcl (mac_unlock_ssh_pubkey)"
  echo "    and rebuild the image:"
  cat "${SSH_KEY}.pub"
fi

if ! security find-generic-password -s ai-server-luks >/dev/null 2>&1; then
  echo "==> Storing the root LUKS passphrase in the Keychain (item: ai-server-luks)"
  echo "    Paste the passphrase (it will not echo); it is the same value as"
  echo "    Infisical /unlock/ROOT_LUKS_KEY:"
  read -rs LUKS_PASS
  security add-generic-password -s ai-server-luks -a "$USER" -w "$LUKS_PASS" -U
  unset LUKS_PASS
fi

if ! security find-generic-password -s ai-server-ntfy >/dev/null 2>&1; then
  echo "==> Storing the ntfy topic URL in the Keychain (item: ai-server-ntfy)"
  echo "    Paste the full URL (same as Infisical /server/NTFY_TOPIC_URL):"
  read -rs NTFY_URL
  security add-generic-password -s ai-server-ntfy -a "$USER" -w "$NTFY_URL" -U
  unset NTFY_URL
fi

echo "==> Installing launchd agent"
sed "s|__HOME__|${HOME}|g" com.ai-server.unlock.plist > "$PLIST_DEST"
launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo "==> Done. The agent polls every 30 s while this Mac is awake."
echo "    Logs: ~/.local/state/ai-server-unlock/agent.log"
