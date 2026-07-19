#!/usr/bin/env bash
# Shared helpers for the bootstrap scripts. Sourced by every phase module and
# by bootstrap.sh / preflight.sh. Never executed directly.
#
# Conventions inherited by all modules:
#   - set -euo pipefail
#   - honour DRY_RUN (print, don't execute) and ASSUME_YES (skip confirms)
#   - secrets are piped straight into their store: never echoed, never on argv
#
# shellcheck shell=bash

# Guard against double-sourcing when a module is run under bootstrap.sh.
[[ -n "${_BOOTSTRAP_LIB_SOURCED:-}" ]] && return 0
_BOOTSTRAP_LIB_SOURCED=1

# ---- Output -----------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_yel=$'\033[33m'
  _c_blu=$'\033[34m'; _c_dim=$'\033[2m'; _c_rst=$'\033[0m'
else
  _c_red=''; _c_grn=''; _c_yel=''; _c_blu=''; _c_dim=''; _c_rst=''
fi

step() { printf '%s\n' "${_c_blu}==>${_c_rst} $*" >&2; }
info() { printf '%s\n' "    $*" >&2; }
ok()   { printf '%s\n' "    ${_c_grn}OK${_c_rst}   $*" >&2; }
warn() { printf '%s\n' "    ${_c_yel}WARN${_c_rst} $*" >&2; }
err()  { printf '%s\n' "    ${_c_red}FAIL${_c_rst} $*" >&2; }
die()  { printf '%s\n' "${_c_red}error:${_c_rst} $*" >&2; exit 1; }

# ---- Preconditions ----------------------------------------------------------
require_cmd() { # require_cmd <name> [install-hint]
  command -v "$1" >/dev/null 2>&1 && return 0
  # A dry-run previews intended actions even if a tool isn't installed yet.
  is_dry && { warn "'$1' not found (ok for --dry-run)"; return 0; }
  die "'$1' not found${2:+ — $2}"
}

require_env() { # require_env VAR "how to obtain it" — for seed credentials
  local name="$1" hint="${2:-}"
  [[ -n "${!name:-}" ]] && return 0
  # A dry-run should preview actions without every seed present.
  is_dry && { warn "seed \$$name not set (ok for --dry-run)"; return 0; }
  die "seed credential \$$name is not set${hint:+ ($hint)}"
}

# ---- Dry-run / confirm ------------------------------------------------------
is_dry() { [[ "${DRY_RUN:-false}" == "true" ]]; }

# run: execute a NON-SECRET command, or just print it under --dry-run.
run() {
  if is_dry; then
    printf '%s\n' "${_c_dim}dry-run:${_c_rst} $*" >&2
  else
    "$@"
  fi
}

# dry_skip: announce a secret-bearing action that we won't run under --dry-run.
# Returns 0 (caller should `dry_skip "..." && return`) when dry.
dry_skip() {
  if is_dry; then
    printf '%s\n' "${_c_dim}dry-run:${_c_rst} $*" >&2
    return 0
  fi
  return 1
}

confirm() { # confirm "prompt" — honoured unless ASSUME_YES=true or dry-run
  [[ "${ASSUME_YES:-false}" == "true" ]] && return 0
  is_dry && return 0
  local reply
  printf '%s [y/N] ' "$*" >&2
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---- Secrets ----------------------------------------------------------------
# A 48-byte base64 random secret (matches openssl rand -base64 48 used across
# the repo's runbooks for LUKS material).
gen_secret() { openssl rand -base64 48 | tr -d '\n'; }

# ---- Config -----------------------------------------------------------------
# Locate and source bootstrap.env (non-secret config), then apply defaults so a
# partial file still works. Safe to call more than once.
load_env() {
  [[ -n "${_BOOTSTRAP_ENV_LOADED:-}" ]] && return 0
  _BOOTSTRAP_ENV_LOADED=1
  local here="${BOOTSTRAP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  if [[ -f "$here/bootstrap.env" ]]; then
    # shellcheck disable=SC1091
    source "$here/bootstrap.env"
  fi
  : "${INFISICAL_DOMAIN:=https://eu.infisical.com}"
  : "${INFISICAL_ENV:=prod}"
  : "${INFISICAL_PROJECT_SLUG:=menegroth}"
  : "${TF_CLOUD_ORGANIZATION:=menegroth}"
  : "${HCLOUD_LOCATION:=nbg1}"
  : "${TAILNET:=-}"
  : "${TS_API_BASE:=https://api.tailscale.com/api/v2}"
  : "${SERVER_TAG:=tag:server}"
  : "${CI_TAG:=tag:ci}"
  : "${BOOT_TAG:=tag:boot-unlock}"
  : "${OP_VAULT:=Menegroth}"
  : "${BOOT_HOSTNAME:=menegroth-server-boot}"
  : "${ADMIN_SSH_COMMENT:=menegroth-server-admin}"
  : "${NTFY_BASE:=https://ntfy.sh}"
}

# ---- Infisical --------------------------------------------------------------
# Writing needs a *user* login (`infisical login`) or INFISICAL_TOKEN — the
# read-only `ci` identity cannot write. Values are passed on argv (a CLI
# limitation); see the argv-exposure note in the bootstrap docs.
infisical_ready() {
  require_cmd infisical "https://infisical.com/docs/cli/overview"
  if [[ -z "${INFISICAL_PROJECT_ID:-}" || "${INFISICAL_PROJECT_ID:-}" == "REPLACE_WITH_PROJECT_ID" ]]; then
    is_dry && { warn "INFISICAL_PROJECT_ID not set (ok for --dry-run)"; return 0; }
    die "INFISICAL_PROJECT_ID is not set in bootstrap.env (Infisical console -> Project Settings -> Project ID)"
  fi
}

infisical_set() { # infisical_set <path> <KEY> <value>
  if is_dry; then
    printf '%s\n' "${_c_dim}dry-run:${_c_rst} infisical set $2 at path $1" >&2
    return 0
  fi
  infisical secrets set "$2=$3" \
    --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" \
    --path="$1" --domain="$INFISICAL_DOMAIN" >/dev/null
}

infisical_get() { # infisical_get <path> <KEY> -> value on stdout ("" if absent)
  infisical secrets get "$2" \
    --projectId="${INFISICAL_PROJECT_ID:-}" --env="$INFISICAL_ENV" \
    --path="$1" --domain="$INFISICAL_DOMAIN" --plain 2>/dev/null || true
}

# ---- 1Password --------------------------------------------------------------
# Project scripts NEVER use a personal `op` session: every call runs as a
# vault-scoped service account, so 1Password enforces Menegroth-only access
# server-side (service accounts can never be granted the Private vault).
#   - bootstrap phases -> menegroth-bootstrap SA (read+write items) via the
#     $MENEGROTH_OP_BOOTSTRAP_TOKEN seed; REVOKE it once bootstrap completes.
#   - Mac agent / preflight -> menegroth-unlock SA (read-only) via the 0600
#     token file written by macos/install.sh (survives Mac reboots).
op_bootstrap_ready() {
  require_cmd op "brew install 1password-cli"
  if [[ -z "${MENEGROTH_OP_BOOTSTRAP_TOKEN:-}" ]]; then
    is_dry && { warn "seed \$MENEGROTH_OP_BOOTSTRAP_TOKEN not set (ok for --dry-run)"; return 0; }
    die "seed \$MENEGROTH_OP_BOOTSTRAP_TOKEN is not set — export the menegroth-bootstrap service-account token (README seed steps). Project scripts never use a personal op session."
  fi
}

op_sa() { # run op as the bootstrap service account (Menegroth vault only)
  OP_SERVICE_ACCOUNT_TOKEN="${MENEGROTH_OP_BOOTSTRAP_TOKEN:-}" op "$@"
}

# ---- Tailscale API ----------------------------------------------------------
ts_api() { # ts_api <METHOD> <path-under-tailnet> [json-body] -> response body
  local method="$1" path="$2" data="${3:-}" url
  url="$TS_API_BASE/tailnet/$TAILNET$path"
  if [[ -n "$data" ]]; then
    curl -fsS -u "${TS_API_TOKEN:-}:" -H 'Content-Type: application/json' \
      -X "$method" --data-binary "$data" "$url"
  else
    curl -fsS -u "${TS_API_TOKEN:-}:" -X "$method" "$url"
  fi
}
