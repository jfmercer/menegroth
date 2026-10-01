#!/usr/bin/env bash
# Phase 40 — GitHub: the only three repo secrets + repo variables (the HCP
# org, and the operator's optional dotfiles).
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

variable_exists() { gh variable list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

set_variable() { # set_variable NAME value — repo VARIABLE (not secret), non-sensitive
  local name="$1" val="$2"
  if variable_exists "$name"; then
    ok "$name exists — left unchanged (gh variable set $name to change it)"
  elif dry_skip "gh variable set $name=$val"; then
    :
  else
    gh variable set "$name" --body "$val"
    ok "$name=$val set"
  fi
}

step "GitHub repo variable"
set_variable TF_CLOUD_ORGANIZATION "$TF_CLOUD_ORGANIZATION"

# Optional operator dotfiles (ansible/roles/dotfiles). Personal settings live
# in GitHub repository variables, never in this repo's source.
step "Operator dotfiles (optional)"
if [[ -z "${DOTFILES_REPO:-}" ]]; then
  info "DOTFILES_REPO not set in bootstrap.env — no dotfiles will be installed"
else
  [[ "${DOTFILES_REF:-}" =~ ^[0-9a-f]{40}$ ]] \
    || die "DOTFILES_REF must be a full 40-character commit SHA (got '${DOTFILES_REF:-}')"
  set_variable DOTFILES_REPO "$DOTFILES_REPO"
  set_variable DOTFILES_REF "$DOTFILES_REF"
  [[ -z "${DOTFILES_DEST:-}" ]] || set_variable DOTFILES_DEST "$DOTFILES_DEST"
fi

ok "GitHub phase complete"
