#!/usr/bin/env bash
# One-time bootstrap orchestrator for the menegroth server.
#
# Creates/stores every credential the CI pipeline needs, from a small set of
# hand-made seed credentials (see bootstrap.env.example). Idempotent: each
# phase checks for existing state before creating. Run --dry-run first.
#
# Usage:
#   ./bootstrap.sh [--dry-run] [--yes] [phase ...]
#
#   phases (default: all, in this order):
#     10-onepassword   1Password vault, items, unlock SSH key, service account
#     20-tailscale     ACL push + server/boot auth keys
#     30-infisical     generate + store all /ci /server /unlock secrets
#     40-github        the three GitHub secrets + TF_CLOUD_ORGANIZATION variable
#
# After a successful run, validate with ./preflight.sh before dispatching the
# Packer build.
set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOOTSTRAP_DIR
# shellcheck source=lib.sh
source "$BOOTSTRAP_DIR/lib.sh"

ALL_PHASES=(10-onepassword 20-tailscale 30-infisical 40-github)

DRY_RUN=false
ASSUME_YES=false
phases=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes | -y) ASSUME_YES=true ;;
    -h | --help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag: $arg" ;;
    *) phases+=("$arg") ;;
  esac
done
export DRY_RUN ASSUME_YES
[[ ${#phases[@]} -eq 0 ]] && phases=("${ALL_PHASES[@]}")

load_env
require_cmd openssl

is_dry && step "DRY RUN — no changes will be made"

for phase in "${phases[@]}"; do
  script="$BOOTSTRAP_DIR/${phase}.sh"
  [[ -f "$script" ]] || die "no such phase: $phase (expected $script)"
  step "Phase ${phase}"
  bash "$script"
done

step "Bootstrap phases complete"
info "Next: ./preflight.sh   then dispatch the 'Packer FDE image' workflow."
