#!/usr/bin/env bash
# Tailscale API helper for CI: list, delete, and rename tailnet devices.
#
# Authenticates as the devices OAuth client (/ci/TS_DEVICES_OAUTH_CLIENT_ID +
# /ci/TS_DEVICES_OAUTH_SECRET: scope devices:core, tags tag:server +
# tag:boot-unlock), so it only ever sees and changes devices carrying those
# tags, never a person's device. Used by the image test
# (scripts/ci/image-test.sh) and the Terraform workflow's image roll.
#
# usage: tailnet-devices.sh list                    JSON array of devices
#        tailnet-devices.sh delete <node-id>        404 counts as deleted
#        tailnet-devices.sh rename <node-id> <name>
set -euo pipefail

: "${TS_DEVICES_OAUTH_CLIENT_ID:?not set: create the devices OAuth client (docs/runbooks/bootstrap-checklist.md) and store it in Infisical /ci}"
: "${TS_DEVICES_OAUTH_SECRET:?not set: see TS_DEVICES_OAUTH_CLIENT_ID}"

API=https://api.tailscale.com/api/v2

# Exchange the client credentials for a short-lived API token. The secret is
# read from stdin, so it never appears on curl's argv.
token() {
  local tok
  tok="$(printf '%s' "$TS_DEVICES_OAUTH_SECRET" | curl -sS --fail-with-body \
    -d "client_id=$TS_DEVICES_OAUTH_CLIENT_ID" --data-urlencode client_secret@- \
    "$API/oauth/token" | jq -r .access_token)"
  [[ -n "$tok" && "$tok" != null ]] || { echo "tailnet-devices: OAuth token exchange failed" >&2; return 1; }
  printf '%s' "$tok"
}

# api <METHOD> <path> [json-body] — prints the body; the HTTP status (or
# curl's error) goes to $status_file. The token travels in a curl config on
# stdin, never on argv.
api() {
  local args=(-sS -X "$1" -w '%{stderr}%{http_code}' -K- "$API$2")
  [[ $# -ge 3 ]] && args+=(-H 'Content-Type: application/json' --data-binary "$3")
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl "${args[@]}" 2>"$status_file"
}

status_file="$(mktemp)"
trap 'rm -f "$status_file"' EXIT
TOKEN="$(token)"

case "${1:-}" in
  list)
    body="$(api GET "/tailnet/-/devices?fields=all")"
    [[ "$(cat "$status_file")" == 200 ]] || { echo "tailnet-devices: list failed (HTTP $(cat "$status_file")): $body" >&2; exit 1; }
    jq '.devices // []' <<<"$body"
    ;;
  delete)
    [[ $# -eq 2 ]] || { echo "usage: tailnet-devices.sh delete <node-id>" >&2; exit 2; }
    body="$(api DELETE "/device/$2")"
    case "$(cat "$status_file")" in
      200 | 204 | 404) echo "tailnet-devices: removed $2 from the tailnet" >&2 ;;
      *) echo "tailnet-devices: delete $2 failed (HTTP $(cat "$status_file")): $body" >&2; exit 1 ;;
    esac
    ;;
  rename)
    [[ $# -eq 3 ]] || { echo "usage: tailnet-devices.sh rename <node-id> <name>" >&2; exit 2; }
    body="$(api POST "/device/$2/name" "$(jq -nc --arg n "$3" '{name: $n}')")"
    [[ "$(cat "$status_file")" =~ ^20[04]$ ]] || { echo "tailnet-devices: rename $2 failed (HTTP $(cat "$status_file")): $body" >&2; exit 1; }
    echo "tailnet-devices: renamed $2 to $3" >&2
    ;;
  *)
    echo "usage: tailnet-devices.sh list | delete <node-id> | rename <node-id> <name>" >&2
    exit 2
    ;;
esac
