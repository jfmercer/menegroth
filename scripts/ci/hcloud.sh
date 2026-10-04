#!/usr/bin/env bash
# Hetzner Cloud API helper, sourced by scripts/ci/image-test.sh,
# scripts/ci/image-roll.sh, and scripts/ci/teardown.sh.
#
# hc <METHOD> <path> [json-body] — prints the response body. On an HTTP error
# it prints the status and body to stderr and returns 1. The token travels in
# a curl config on stdin, never on argv. HCLOUD_ENDPOINT overrides the API
# URL, as it does for the hcloud provider and CLI (the teardown's tests).
#
# hc_list <collection> [query] — every item of a paginated collection as one
# JSON array, e.g. `hc_list servers` or `hc_list images type=snapshot`.

hc() {
  : "${HCLOUD_TOKEN:?}"
  local args=(-sS -X "$1" -w '\n%{http_code}' -K- "${HCLOUD_ENDPOINT:-https://api.hetzner.cloud/v1}$2")
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

hc_list() {
  local base="/$1?${2:+$2&}per_page=50" page=1 body all='[]'
  while [[ "$page" != null ]]; do
    body="$(hc GET "$base&page=$page")" || return 1
    all="$(jq -c --argjson all "$all" --arg k "$1" '$all + .[$k]' <<<"$body")"
    page="$(jq -r '.meta.pagination.next_page' <<<"$body")"
  done
  printf '%s' "$all"
}
