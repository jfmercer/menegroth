#!/usr/bin/env bash
# Phase 10 — 1Password: ensure the Menegroth vault holds the unlock items.
#
# SCOPE: every op call here runs as the menegroth-bootstrap SERVICE ACCOUNT
# ($MENEGROTH_OP_BOOTSTRAP_TOKEN seed; read+write items on the Menegroth vault ONLY) —
# never a personal 1Password session. 1Password enforces the vault scope
# server-side, and service accounts can never be granted your Private vault.
# The vault itself and the two service accounts are hand-made seed steps
# (README): a service account cannot create other service accounts. REVOKE
# menegroth-bootstrap once the bootstrap is complete.
#
# Item secrets are generated *by 1Password* (--generate-password /
# --ssh-generate-key) so this script never holds the passphrase or private
# key. Idempotent: existing items are left untouched.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOOTSTRAP_DIR="$HERE"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
load_env

require_cmd jq "brew install jq"
op_bootstrap_ready

# ---- Vault access (never creation — the vault is a seed step) ---------------
step "Vault: $OP_VAULT (as the menegroth-bootstrap service account)"
if dry_skip "verify service-account access to vault $OP_VAULT"; then
  :
elif op_sa vault get "$OP_VAULT" >/dev/null 2>&1; then
  ok "vault reachable — and it is the ONLY vault this token can see"
else
  die "cannot read vault '$OP_VAULT' as the bootstrap service account — create the vault and the menegroth-bootstrap SA per the README seed steps"
fi

# ---- luks-passphrase (1Password-generated; we never see the value) ----------
step "Item: luks-passphrase (root LUKS passphrase — primary copy)"
if dry_skip "ensure item luks-passphrase (1Password-generated, 40 chars)"; then
  :
elif op_sa item get luks-passphrase --vault "$OP_VAULT" >/dev/null 2>&1; then
  ok "exists — left unchanged (regenerating would strand the encrypted disk)"
else
  # Letters+digits only: long enough to be strong, still typeable at the
  # Hetzner console break-glass prompt. Field label 'password' matches the
  # op://.../luks-passphrase/password reference the Mac agent reads.
  op_sa item create --category password --title luks-passphrase \
    --vault "$OP_VAULT" --generate-password='40,letters,digits' >/dev/null
  ok "created (40-char generated passphrase)"
fi

# ---- ntfy (notification topic URL) ------------------------------------------
step "Item: ntfy (alert topic URL)"
if dry_skip "ensure item ntfy (url field)"; then
  :
elif op_sa item get ntfy --vault "$OP_VAULT" >/dev/null 2>&1; then
  ok "exists"
else
  topic_url="${NTFY_TOPIC_URL:-$NTFY_BASE/menegroth-alerts-$(openssl rand -hex 6)}"
  # Field labelled 'url' so op://.../ntfy/url resolves.
  op_sa item create --category "Secure Note" --title ntfy \
    --vault "$OP_VAULT" "url[url]=$topic_url" >/dev/null
  ok "created ($topic_url)"
fi

# ---- unlock-ssh-key (generated inside 1Password) ----------------------------
step "Item: unlock-ssh-key (dropbear-trusted key; private half never leaves 1P)"
if dry_skip "ensure item unlock-ssh-key (ed25519, generated in-vault)"; then
  :
elif op_sa item get unlock-ssh-key --vault "$OP_VAULT" >/dev/null 2>&1; then
  ok "exists"
else
  op_sa item create --category 'SSH Key' --title unlock-ssh-key \
    --vault "$OP_VAULT" --ssh-generate-key ed25519 >/dev/null
  ok "created (ed25519)"
fi
if ! is_dry; then
  pub="$(op_sa read "op://$OP_VAULT/unlock-ssh-key/public key")"
  info "public key (phase 30 stores this at /unlock/MAC_UNLOCK_SSH_PUBKEY):"
  printf '      %s\n' "$pub" >&2
fi

# ---- Unlock service-account token (the Mac agent's credential) --------------
step "Unlock token (menegroth-unlock service account, read-only)"
if [[ -n "${MENEGROTH_OP_UNLOCK_TOKEN:-}" ]]; then
  ok "\$MENEGROTH_OP_UNLOCK_TOKEN is set in this shell"
else
  info "\$MENEGROTH_OP_UNLOCK_TOKEN not set here — the token is never stored on"
  info "disk; export it before running macos/install.sh and preflight.sh, and"
  info "re-run macos/install.sh after each Mac reboot (README seed steps)."
fi

ok "1Password phase complete"
