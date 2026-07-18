#!/usr/bin/env bash
# Phase 20 — Tailscale: apply the tailnet ACL and mint the join keys.
#
# All Tailscale API work lives here. The minted auth keys are stored into
# Infisical the instant they are created, because Tailscale shows an auth key
# exactly once — it cannot be re-read later. Idempotent: a key already present
# in Infisical is not re-minted (avoids piling up keys on re-runs).
#
# Seed: TS_API_TOKEN (admin console -> Settings -> Keys -> API access token).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOOTSTRAP_DIR="$HERE"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
load_env

require_cmd curl
require_cmd jq
require_env TS_API_TOKEN "admin console -> Settings -> Keys -> generate API access token"
infisical_ready

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
  warn "ACL push skipped — auth keys below need the three tags to already be owned"
fi

# ---- Auth keys --------------------------------------------------------------
mint_key() { # mint_key <tag> <ephemeral true|false> <description> -> key
  local tag="$1" ephemeral="$2" desc="$3" body
  body="$(jq -nc --arg tag "$tag" --argjson eph "$ephemeral" --arg desc "$desc" \
    '{capabilities:{devices:{create:{reusable:true,ephemeral:$eph,preauthorized:true,tags:[$tag]}}},expirySeconds:7776000,description:$desc}')"
  ts_api POST /keys "$body" | jq -r '.key'
}

store_key() { # store_key <infisical-path> <KEY-name> <tag> <ephemeral> <desc>
  local path="$1" name="$2" tag="$3" ephemeral="$4" desc="$5"
  if [[ -n "$(infisical_get "$path" "$name")" ]]; then
    ok "$name already in Infisical $path — not re-minting"
  elif dry_skip "mint $tag key (ephemeral=$ephemeral) -> $path/$name"; then
    :
  else
    local key
    key="$(mint_key "$tag" "$ephemeral" "$desc")"
    [[ -n "$key" && "$key" != "null" ]] || die "failed to mint $tag auth key (check TS_API_TOKEN and that $tag is owned in the ACL)"
    infisical_set "$path" "$name" "$key"
    unset key
    ok "minted $tag key -> $path/$name"
  fi
}

step "Server join key ($SERVER_TAG, reusable, non-ephemeral)"
store_key /ci TS_SERVER_AUTHKEY "$SERVER_TAG" false "menegroth server join"

step "Boot-unlock key ($BOOT_TAG, reusable, ephemeral)"
store_key /unlock TS_BOOT_AUTHKEY "$BOOT_TAG" true "menegroth initramfs boot-unlock"

ok "Tailscale phase complete"
