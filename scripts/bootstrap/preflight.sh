#!/usr/bin/env bash
# Preflight — verify the bootstrap is complete BEFORE dispatching the Packer
# build. Read-only. Prints a ✓/✗ checklist and exits non-zero on any FAIL.
#
# FAIL  = a required credential/name is missing or wrong -> fix before CI.
# WARN  = could not verify (tool missing / not logged in), or an expected
#         not-yet condition (e.g. FDE snapshot before the first build).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOOTSTRAP_DIR="$HERE"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
load_env

FAILURES=0
pass() { ok "$1"; }
fail() { err "$1"; FAILURES=$((FAILURES + 1)); }

# ---- GitHub -----------------------------------------------------------------
step "GitHub — 3 secrets + 1 variable"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  [[ -n "${GITHUB_REPO:-}" ]] && export GH_REPO="$GITHUB_REPO"
  gh_names="$(gh secret list 2>/dev/null | awk '{print $1}')"
  for s in TF_API_TOKEN INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET; do
    if grep -qx "$s" <<<"$gh_names"; then pass "secret $s"; else fail "secret $s missing"; fi
  done
  if gh variable list 2>/dev/null | awk '{print $1}' | grep -qx TF_CLOUD_ORGANIZATION; then
    pass "variable TF_CLOUD_ORGANIZATION"
  else
    fail "variable TF_CLOUD_ORGANIZATION missing"
  fi
else
  warn "skipped — gh not installed or not authenticated (gh auth login)"
fi

# ---- Infisical --------------------------------------------------------------
step "Infisical — required secrets by exact name"
CI_KEYS="HCLOUD_TOKEN TS_OAUTH_CLIENT_ID TS_OAUTH_SECRET TS_SERVER_AUTHKEY SSH_PRIVATE_KEY ADMIN_SSH_PUBLIC_KEY SERVER_IDENTITY_CLIENT_ID SERVER_IDENTITY_CLIENT_SECRET"
SERVER_KEYS="DATA_VOLUME_LUKS_KEY ANTHROPIC_API_KEY NTFY_TOPIC_URL"
UNLOCK_KEYS="ROOT_LUKS_KEY TS_BOOT_AUTHKEY MAC_UNLOCK_SSH_PUBKEY"
if command -v infisical >/dev/null 2>&1 && [[ -n "${INFISICAL_PROJECT_ID:-}" && "${INFISICAL_PROJECT_ID:-}" != "REPLACE_WITH_PROJECT_ID" ]] \
  && infisical secrets --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" --path=/ci --domain="$INFISICAL_DOMAIN" >/dev/null 2>&1; then
  check_path() { # check_path <path> <keys...>
    local path="$1"; shift
    local k
    for k in "$@"; do
      if [[ -n "$(infisical_get "$path" "$k")" ]]; then pass "$path/$k"; else fail "$path/$k missing/empty"; fi
    done
  }
  # shellcheck disable=SC2086
  check_path /ci $CI_KEYS
  # shellcheck disable=SC2086
  check_path /server $SERVER_KEYS
  # shellcheck disable=SC2086
  check_path /unlock $UNLOCK_KEYS
else
  warn "skipped — infisical not installed/logged in, or INFISICAL_PROJECT_ID unset"
fi

# ---- 1Password --------------------------------------------------------------
# Checks run as the menegroth-unlock service account (the Mac agent's actual
# credential) — never a personal op session. Passing here proves the exact
# token the agent will use can read all three items, and nothing else.
step "1Password — vault items readable via the menegroth-unlock service account"
op_read_check() { # op_read_check <op-reference>
  OP_SERVICE_ACCOUNT_TOKEN="$MENEGROTH_OP_UNLOCK_TOKEN" op read "$1" >/dev/null 2>&1
}
if ! command -v op >/dev/null 2>&1; then
  warn "skipped — op (1Password CLI) not installed"
elif [[ -z "${MENEGROTH_OP_UNLOCK_TOKEN:-}" ]]; then
  fail "\$MENEGROTH_OP_UNLOCK_TOKEN not set — export the menegroth-unlock service-account token (README seed steps); it is never stored on disk"
else
  if op_read_check "op://$OP_VAULT/luks-passphrase/password"; then pass "luks-passphrase"; else fail "luks-passphrase unreadable"; fi
  if op_read_check "op://$OP_VAULT/unlock-ssh-key/private key?ssh-format=openssh"; then pass "unlock-ssh-key"; else fail "unlock-ssh-key unreadable"; fi
  if op_read_check "op://$OP_VAULT/ntfy/url"; then pass "ntfy/url"; else fail "ntfy/url unreadable"; fi
fi

# ---- Tailscale --------------------------------------------------------------
step "Tailscale — ACL owns the three tags"
if command -v curl >/dev/null 2>&1 && [[ -n "${TS_API_TOKEN:-}" ]]; then
  acl="$(ts_api GET /acl 2>/dev/null || true)"
  for t in "$SERVER_TAG" "$CI_TAG" "$BOOT_TAG"; do
    if grep -q "$t" <<<"$acl"; then pass "ACL contains $t"; else fail "ACL missing $t"; fi
  done
else
  warn "skipped — set TS_API_TOKEN (API access token) to verify the ACL"
fi

# ---- Hetzner ----------------------------------------------------------------
step "Hetzner — token works; FDE snapshot present"
if command -v hcloud >/dev/null 2>&1 && [[ -n "${HCLOUD_TOKEN:-}" ]]; then
  if HCLOUD_TOKEN="$HCLOUD_TOKEN" hcloud image list -o noheader >/dev/null 2>&1; then
    pass "HCLOUD_TOKEN valid"
    if [[ -n "$(HCLOUD_TOKEN="$HCLOUD_TOKEN" hcloud image list -t snapshot -l fde=true -o noheader 2>/dev/null)" ]]; then
      pass "FDE snapshot exists (fde=true)"
    else
      warn "no fde=true snapshot yet — expected until you run the Packer build (step 7)"
    fi
  else
    fail "HCLOUD_TOKEN invalid (hcloud image list failed)"
  fi
else
  warn "skipped — install hcloud and export HCLOUD_TOKEN to verify the token/snapshot"
fi

# ---- Summary ----------------------------------------------------------------
echo >&2
if [[ "$FAILURES" -eq 0 ]]; then
  step "Preflight passed — no failures. (Review any WARN lines above.)"
else
  die "Preflight found $FAILURES failure(s) — fix them before dispatching the build."
fi
