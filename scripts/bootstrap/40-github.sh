#!/usr/bin/env bash
# Phase 40 — GitHub: the only three repo secrets + the org variable.
#
# By design nothing else lives in GitHub; every other credential is fetched
# from Infisical at run time. Secret values are piped via stdin (never argv,
# never a trailing newline). Idempotent: an existing secret/variable is left
# unchanged.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOOTSTRAP_DIR="$HERE"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
load_env

require_cmd gh "https://cli.github.com"
is_dry || gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"
# gh honours GH_REPO to target a repo; otherwise it infers from the cwd repo.
[[ -n "${GITHUB_REPO:-}" ]] && export GH_REPO="$GITHUB_REPO"

secret_exists() { gh secret list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

set_secret() { # set_secret NAME value
  local name="$1" val="$2"
  if secret_exists "$name"; then
    ok "$name exists — left unchanged"
  elif [[ -z "$val" ]]; then
    is_dry && { warn "$name: no value yet (ok for --dry-run)"; return 0; }
    die "$name: no value provided — set the seed env var"
  elif dry_skip "gh secret set $name (via stdin)"; then
    :
  else
    printf '%s' "$val" | gh secret set "$name"
    ok "$name set"
  fi
}

step "GitHub repo secrets (exactly three)"
set_secret TF_API_TOKEN            "${TF_API_TOKEN:-}"
set_secret INFISICAL_CLIENT_ID     "${INFISICAL_CLIENT_ID:-}"
set_secret INFISICAL_CLIENT_SECRET "${INFISICAL_CLIENT_SECRET:-}"

step "GitHub repo variable"
if gh variable list 2>/dev/null | awk '{print $1}' | grep -qx TF_CLOUD_ORGANIZATION; then
  ok "TF_CLOUD_ORGANIZATION exists — left unchanged"
elif dry_skip "gh variable set TF_CLOUD_ORGANIZATION=$TF_CLOUD_ORGANIZATION"; then
  :
else
  gh variable set TF_CLOUD_ORGANIZATION --body "$TF_CLOUD_ORGANIZATION"
  ok "TF_CLOUD_ORGANIZATION=$TF_CLOUD_ORGANIZATION set"
fi

ok "GitHub phase complete"
