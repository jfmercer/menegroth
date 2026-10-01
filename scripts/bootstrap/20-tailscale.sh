#!/usr/bin/env bash
# Phase 20 — Tailscale: apply the tailnet ACL.
#
# No auth keys are minted here any more (D10): auth keys expire after at most
# 90 days, which silently broke both the image-embedded boot unlock and
# fresh-server joins. The tag:server and tag:boot-unlock credentials are now
# non-expiring OAuth client secrets — hand-made seeds (README), stored into
# Infisical by phase 30. The ACL must be applied BEFORE those clients are
# created: an OAuth client can only be given tags that the policy defines.
#
# Seed: TS_API_TOKEN (admin console -> Settings -> Keys -> API access token).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOOTSTRAP_DIR="$HERE"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
load_env

require_cmd curl
require_env TS_API_TOKEN "admin console -> Settings -> Keys -> generate API access token"

# ---- ACL policy -------------------------------------------------------------
# Mirrors docs/architecture.md#tailscale-acls. Replaces the whole policy file,
# so we confirm first. dropbear (tag:boot-unlock:22) is an L3 rule, not an ssh
# rule, because the initramfs runs ordinary SSH, not Tailscale SSH.
read -r -d '' ACL_POLICY <<JSON || true
{
  "tagOwners": {
    "$SERVER_TAG": ["autogroup:admin"],
    "$CI_TAG": ["autogroup:admin"],
    "$BOOT_TAG": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["$SERVER_TAG:*"] },
    { "action": "accept", "src": ["$CI_TAG"], "dst": ["$SERVER_TAG:22"] },
    { "action": "accept", "src": ["autogroup:member"], "dst": ["$BOOT_TAG:22"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["$SERVER_TAG"], "users": ["admin", "root"] },
    { "action": "accept", "src": ["$CI_TAG"], "dst": ["$SERVER_TAG"], "users": ["admin"] }
  ]
}
JSON

step "Tailnet ACL policy"
if confirm "Overwrite the tailnet ACL with the menegroth policy (replaces the whole policy file)?"; then
  if dry_skip "POST tailnet ACL policy"; then
    :
  else
    ts_api POST /acl "$ACL_POLICY" >/dev/null
    ok "ACL applied"
  fi
else
  warn "ACL push skipped — the OAuth clients need the three tags to already be defined"
fi

ok "Tailscale phase complete"
