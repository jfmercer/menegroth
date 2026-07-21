#!/usr/bin/env bash
# Phase 30 — Infisical: populate every secret the pipeline reads at run time.
#
# Three kinds of value:
#   - seeds   : hand-made credentials passed via env (HCLOUD_TOKEN, OAuth, ...)
#   - generated: openssl / ssh-keygen (data-volume key, admin keypair)
#   - from 1Password: the values phase 10 created (root passphrase, pub keys)
#
# The two Tailscale auth keys are written by phase 20 (they are unrepeatable).
# Idempotent: an existing secret is left unchanged (re-runs never rotate keys).
#
# Two projects (free-plan access isolation, D8): /ci and /unlock go to the
# INFISICAL_PROJECT_ID project; /server goes to INFISICAL_SERVER_PROJECT_ID.
# The put/gen_put/op_put helpers route by path automatically (see lib.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOOTSTRAP_DIR="$HERE"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
load_env

require_cmd openssl
require_cmd ssh-keygen
infisical_ready

# put: store a value unless it already exists; hard-fail if a needed value is
# missing on a real run (preflight would otherwise catch it much later).
put() { # put <path> <KEY> <value>
  local path="$1" key="$2" val="$3"
  if [[ -n "$(infisical_get "$path" "$key")" ]]; then
    ok "$key exists in $path — left unchanged"
    return 0
  fi
  if [[ -z "$val" ]]; then
    is_dry && { warn "$key: no value yet (ok for --dry-run)"; return 0; }
    die "$key: no value provided and not already in Infisical — set the seed env var"
  fi
  infisical_set "$path" "$key" "$val"
  ok "$key -> $path"
}

gen_put() { # gen_put <path> <KEY> <generator-command...>
  local path="$1" key="$2"; shift 2
  [[ -n "$(infisical_get "$path" "$key")" ]] && { ok "$key exists in $path — unchanged"; return 0; }
  dry_skip "generate $key -> $path" && return 0
  put "$path" "$key" "$("$@")"
}

op_put() { # op_put <path> <KEY> <op://reference> — reads as the bootstrap SA
  local path="$1" key="$2" ref="$3"
  [[ -n "$(infisical_get "$path" "$key")" ]] && { ok "$key exists in $path — unchanged"; return 0; }
  dry_skip "read $ref from 1Password (bootstrap SA) -> $path/$key" && return 0
  op_bootstrap_ready
  put "$path" "$key" "$(op_sa read "$ref")"
}

# ---- Seeds (from the environment) -------------------------------------------
step "/ci — seed credentials"
put /ci HCLOUD_TOKEN                  "${HCLOUD_TOKEN:-}"
put /ci TS_OAUTH_CLIENT_ID           "${TS_OAUTH_CLIENT_ID:-}"
put /ci TS_OAUTH_SECRET              "${TS_OAUTH_SECRET:-}"
put /ci SERVER_IDENTITY_CLIENT_ID     "${SERVER_IDENTITY_CLIENT_ID:-}"
put /ci SERVER_IDENTITY_CLIENT_SECRET "${SERVER_IDENTITY_CLIENT_SECRET:-}"

# ---- Generated --------------------------------------------------------------
step "/server — generated data-volume LUKS key (server project)"
gen_put /server DATA_VOLUME_LUKS_KEY gen_secret

# Gate on the PUBLIC key (what the Terraform wiring needs). Three cases:
# both present -> skip; private present but public missing (e.g. created by
# hand in step 5) -> derive the public half; neither -> generate a fresh pair.
step "/ci — admin bootstrap SSH keypair"
if [[ -n "$(infisical_get /ci ADMIN_SSH_PUBLIC_KEY)" ]]; then
  ok "ADMIN_SSH_PUBLIC_KEY exists — admin keypair left unchanged"
elif dry_skip "ensure admin keypair in /ci/{SSH_PRIVATE_KEY,ADMIN_SSH_PUBLIC_KEY}"; then
  :
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  existing_priv="$(infisical_get /ci SSH_PRIVATE_KEY)"
  if [[ -n "$existing_priv" ]]; then
    printf '%s\n' "$existing_priv" >"$tmp/id"
    chmod 600 "$tmp/id"
    put /ci ADMIN_SSH_PUBLIC_KEY "$(ssh-keygen -y -f "$tmp/id")"
    ok "derived ADMIN_SSH_PUBLIC_KEY from the existing private key"
  else
    ssh-keygen -t ed25519 -N '' -C "$ADMIN_SSH_COMMENT" -f "$tmp/id" -q
    put /ci SSH_PRIVATE_KEY      "$(cat "$tmp/id")"
    put /ci ADMIN_SSH_PUBLIC_KEY "$(cat "$tmp/id.pub")"
    ok "admin keypair generated"
  fi
  unset existing_priv
  rm -rf "$tmp"
  trap - EXIT
fi

# ---- From 1Password (phase 10 created these) --------------------------------
# /unlock -> CI/unlock project; /server/NTFY_TOPIC_URL -> server project.
step "/unlock and /server — values from 1Password"
op_put /unlock ROOT_LUKS_KEY        "op://$OP_VAULT/luks-passphrase/password"
op_put /unlock MAC_UNLOCK_SSH_PUBKEY "op://$OP_VAULT/unlock-ssh-key/public key"
op_put /server NTFY_TOPIC_URL        "op://$OP_VAULT/ntfy/url"

info "Optional (only if ops_restic_enabled): set /server/RESTIC_REPOSITORY and RESTIC_PASSWORD by hand."
ok "Infisical phase complete"
