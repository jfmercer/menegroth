#!/usr/bin/env bash
# Hetzner Cloud API helper, sourced by scripts/ci/image-test.sh and
# scripts/ci/image-roll.sh.
#
# hc <METHOD> <path> [json-body] — prints the response body. On an HTTP error
# it prints the status and body to stderr and returns 1. The token travels in
# a curl config on stdin, never on argv.

hc() {
  : "${HCLOUD_TOKEN:?}"
  local args=(-sS -X "$1" -w '\n%{http_code}' -K- "https://api.hetzner.cloud/v1$2")
  [[ $# -ge 3 ]] && args+=(-H 'Content-Type: application/json' --data-binary "$3")
  local out code
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$HCLOUD_TOKEN" | curl "${args[@]}")" || return 1
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if [[ "$code" != 2* ]]; then
    printf 'hetzner: %s %s -> HTTP %s: %s\n' "$1" "$2" "$code" "$out" >&2
    return 1
  fi
  printf '%s' "$out"
}
