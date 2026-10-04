#!/usr/bin/env bash
# Render PASS/FAIL/WARN/INFO lines (scripts/verify/*.sh) as a Markdown table
# for the GitHub job summary.
#
# usage: summary.sh <title> <results-file>
set -euo pipefail

title="$1"
results="$2"
[[ -s "$results" ]] || { printf '### %s\n\nNo results (the step failed before checking anything; see the log).\n' "$title"; exit 0; }

count() { grep -c "^$1 " "$results" || true; }
printf '### %s: %s passed, %s failed, %s warnings\n\n' "$title" "$(count PASS)" "$(count FAIL)" "$(count WARN)"
printf '| | Check |\n|---|---|\n'
while IFS= read -r line; do
  status="${line%% *}"
  text="$(sed 's/^[A-Z]* *//; s/|/\\|/g' <<<"$line")"
  case "$status" in
    PASS) icon="✅" ;;
    FAIL) icon="❌" ;;
    WARN) icon="⚠️" ;;
    INFO) icon="ℹ️" ;;
    *) continue ;;
  esac
  printf '| %s | %s |\n' "$icon" "$text"
done <"$results"
