#!/usr/bin/env bash
# Shellcheck every tracked shell script (except raw *.j2) plus the rendered Ansible script
# templates (most *.j2 files are bash — CLAUDE.md keeps them shellcheck-clean).
# Used by .github/workflows/shellcheck.yml and the pre-commit hook.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

uv run --frozen python scripts/ci/render-ansible-templates.py "$out"

scripts=()
while IFS= read -r f; do
  head -n1 "$f" | grep -qE '^#!.*\b(ba)?sh\b' && scripts+=("$f")
done < <(git ls-files -- ":!*.j2")  # templates: checked rendered, below
for f in "$out"/*; do
  head -n1 "$f" | grep -qE '^#!.*\b(ba)?sh\b' && scripts+=("$f")
done

echo "shellcheck: ${#scripts[@]} files"
shellcheck "${scripts[@]}"
