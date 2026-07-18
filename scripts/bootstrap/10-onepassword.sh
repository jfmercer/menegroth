#!/usr/bin/env bash
# Phase 10 — 1Password: the Mac-side unlock vault and its read-only agent.
#
# Creates the AI-Server-Unlock vault and its three items (luks-passphrase,
# ntfy, unlock-ssh-key), plus a read-only service account whose token the Mac
# unlock agent uses. 1Password is the *primary* home of the root passphrase;
# phase 30 copies it (and the two public values) into Infisical.
#
# Secrets are generated *by 1Password* (--generate-password / --ssh-generate-key)
# so this script never holds the passphrase or private key. Idempotent: existing
# items are left untouched.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOOTSTRAP_DIR="$HERE"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
load_env

require_cmd op "brew install 1password-cli"
require_cmd jq "brew install jq"
is_dry || op whoami >/dev/null 2>&1 || die "not signed in to 1Password CLI — run: eval \$(op signin)"

# ---- Vault ------------------------------------------------------------------
step "Vault: $OP_VAULT"
if op vault get "$OP_VAULT" >/dev/null 2>&1; then
  ok "vault exists"
else
  run op vault create "$OP_VAULT" >/dev/null
  ok "created vault"
fi

# ---- luks-passphrase (1Password-generated; we never see the value) ----------
step "Item: luks-passphrase (root LUKS passphrase — primary copy)"
if op item get luks-passphrase --vault "$OP_VAULT" >/dev/null 2>&1; then
  ok "exists — left unchanged (regenerating would strand the encrypted disk)"
else
  # Letters+digits only: long enough to be strong, still typeable at the
  # Hetzner console break-glass prompt. Field label 'password' matches the
  # op://.../luks-passphrase/password reference the Mac agent reads.
  run op item create --category password --title luks-passphrase \
    --vault "$OP_VAULT" --generate-password='40,letters,digits' >/dev/null
  ok "created (40-char generated passphrase)"
fi

# ---- ntfy (notification topic URL) ------------------------------------------
step "Item: ntfy (alert topic URL)"
if op item get ntfy --vault "$OP_VAULT" >/dev/null 2>&1; then
  ok "exists"
else
  topic_url="${NTFY_TOPIC_URL:-$NTFY_BASE/menegroth-alerts-$(openssl rand -hex 6)}"
  # Field labelled 'url' so op://.../ntfy/url resolves.
  run op item create --category "Secure Note" --title ntfy \
    --vault "$OP_VAULT" "url[url]=$topic_url" >/dev/null
  ok "created ($topic_url)"
fi

# ---- unlock-ssh-key (generated inside 1Password) ----------------------------
step "Item: unlock-ssh-key (dropbear-trusted key; private half never leaves 1P)"
if op item get unlock-ssh-key --vault "$OP_VAULT" >/dev/null 2>&1; then
  ok "exists"
else
  run op item create --category 'SSH Key' --title unlock-ssh-key \
    --vault "$OP_VAULT" --ssh-generate-key ed25519 >/dev/null
  ok "created (ed25519)"
fi
if ! is_dry; then
  pub="$(op read "op://$OP_VAULT/unlock-ssh-key/public key")"
  info "public key (phase 30 stores this at /unlock/MAC_UNLOCK_SSH_PUBKEY):"
  printf '      %s\n' "$pub" >&2
fi

# ---- Read-only service account ----------------------------------------------
# The Mac agent authenticates headlessly with this token. read_items on this
# one vault only — the whole point of the split (macos/README.md).
step "Service account: menegroth-unlock (read-only, $OP_VAULT)"
token_file="$HOME/.config/ai-server-unlock/op-token"
if op service-account list 2>/dev/null | grep -qi 'menegroth-unlock'; then
  ok "exists — token not re-emitted (rotate via macos/README.md if lost)"
elif dry_skip "create service account menegroth-unlock and write token to $token_file"; then
  :
else
  mkdir -p "$(dirname "$token_file")"
  # --format json keeps the token off the human-readable output; .token is the
  # field (confirm against your op version if this ever changes).
  token="$(op service-account create menegroth-unlock \
    --vault "$OP_VAULT:read_items" --format json | jq -r '.token')"
  [[ -n "$token" && "$token" != "null" ]] || die "service account created but token not captured"
  ( umask 177; printf '%s\n' "$token" >"$token_file" )
  unset token
  ok "created; token -> $token_file (0600). Run macos/install.sh to load the agent."
fi

ok "1Password phase complete"
