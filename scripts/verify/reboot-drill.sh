#!/usr/bin/env bash
# Reboot drill (opt-in, Verify workflow dispatch): reboot the production
# server and prove it comes back with no human involved. The Mac agent must
# unlock the root volume, and /data must remount from its Infisical key. The
# server checks that follow then confirm everything came up.
#
# Runs on a runner that has joined the tailnet as tag:ci. Needs the Mac
# awake; the server is down for a few minutes.
set -euo pipefail

SERVER_NAME="${SERVER_NAME:-menegroth-server}"

online() { # is the server's tailnet node online?
  tailscale status --json | jq -e --arg n "$SERVER_NAME" \
    '[.Peer // {} | .[] | select(.DNSName | startswith($n + ".")) | .Online] | any' >/dev/null
}
wait_for() { # wait_for <online|offline> <timeout-seconds>
  local deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    if [[ "$1" == online ]] && online; then return 0; fi
    if [[ "$1" == offline ]] && ! online; then return 0; fi
    sleep 10
  done
  return 1
}

online || { echo "::error::$SERVER_NAME is not online; not starting a reboot drill"; exit 1; }
echo "==> Rebooting $SERVER_NAME"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "admin@$SERVER_NAME" sudo systemctl --no-block reboot
start=$SECONDS
wait_for offline 180 || { echo "::error::$SERVER_NAME did not go down within 3 minutes"; exit 1; }
echo "==> Down after $((SECONDS - start))s; waiting for the Mac agent to unlock it"
wait_for online 900 || {
  echo "::error::$SERVER_NAME did not come back within 15 minutes. It is probably waiting at the unlock prompt: is the Mac awake? 'menegroth-server-unlock --diagnose' on the Mac, then docs/troubleshooting.md."
  exit 1
}
echo "==> Back on the tailnet $((SECONDS - start))s after the reboot"
# Let boot finish (services, /data) before the checks run.
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "admin@$SERVER_NAME" 'timeout 600 systemctl is-system-running --wait' || true
echo "==> Boot finished $((SECONDS - start))s after the reboot"
{
  echo "### Reboot drill"
  echo "Rebooted, unlocked unattended, and back on the tailnet in $((SECONDS - start)) s."
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
