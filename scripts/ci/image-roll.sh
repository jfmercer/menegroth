#!/usr/bin/env bash
# Tailnet bookkeeping around an image roll (terraform.yml, replace_server):
# the dead server's node must leave the tailnet so the new server can take
# the name `menegroth-server`, which Ansible's inventory (MagicDNS) targets.
#
# usage: image-roll.sh before   record the current server and its tailnet node
#        image-roll.sh after    once the old server is gone: delete its node,
#                               wait for the new server to join, and give it
#                               the name if the join got a suffixed one
#
# `before` writes OLD_SERVER_ID / OLD_NODE_ID to $GITHUB_ENV for `after`.
# The old node is deleted only once Hetzner no longer has the old server, so
# a failed apply that left the server running never cuts it off the tailnet.
set -euo pipefail

: "${HCLOUD_TOKEN:?}"
SERVER_NAME="${SERVER_NAME:-menegroth-server}"
JOIN_TIMEOUT="${JOIN_TIMEOUT:-1200}" # unlock waits for the Mac agent; allow 20 min
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/ci/hcloud.sh
source "$HERE/hcloud.sh"

server_id() { hc GET "/servers?name=$SERVER_NAME" | jq -r '.servers[0].id // empty'; }

# The production node: tag:server, MagicDNS name exactly <SERVER_NAME>.<tailnet>.
prod_nodes() {
  "$HERE/tailnet-devices.sh" list | jq -r --arg n "$SERVER_NAME" \
    '.[] | select(((.tags // []) | index("tag:server")) and (.name | startswith($n + "."))) | .nodeId'
}

case "${1:-}" in
  before)
    old_server="$(server_id)"
    old_node="$(prod_nodes | head -n1)"
    echo "image-roll: current server ${old_server:-none}, tailnet node ${old_node:-none}" >&2
    {
      echo "OLD_SERVER_ID=$old_server"
      echo "OLD_NODE_ID=$old_node"
      echo "ROLL_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >>"${GITHUB_ENV:-/dev/stdout}"
    ;;
  after)
    : "${ROLL_STARTED:?run 'image-roll.sh before' first}"
    new_server="$(server_id)"
    if [[ -n "${OLD_SERVER_ID:-}" && "$new_server" == "$OLD_SERVER_ID" ]]; then
      echo "::error::image-roll: server $OLD_SERVER_ID still exists, so the apply did not replace it. Its tailnet node was left alone."
      exit 1
    fi
    if [[ -n "${OLD_NODE_ID:-}" ]]; then
      "$HERE/tailnet-devices.sh" delete "$OLD_NODE_ID"
    fi
    [[ -n "$new_server" ]] || { echo "::error::image-roll: no server named $SERVER_NAME after the apply"; exit 1; }

    echo "image-roll: waiting for server $new_server to be unlocked (Mac agent) and join the tailnet" >&2
    deadline=$((SECONDS + JOIN_TIMEOUT))
    while ((SECONDS < deadline)); do
      node="$("$HERE/tailnet-devices.sh" list | jq -c --arg h "$SERVER_NAME" --arg t "$ROLL_STARTED" \
        '[.[] | select(((.tags // []) | index("tag:server")) and .hostname == $h
                       and .created >= $t and .connectedToControl)] | first // empty')"
      if [[ -n "$node" ]]; then
        id="$(jq -r .nodeId <<<"$node")"
        name="$(jq -r .name <<<"$node")"
        echo "image-roll: the new server joined as $name ($id)" >&2
        if [[ "$name" != "$SERVER_NAME".* ]]; then
          "$HERE/tailnet-devices.sh" rename "$id" "$SERVER_NAME"
        fi
        exit 0
      fi
      sleep 20
    done
    echo "::error::image-roll: the new server did not join the tailnet within $((JOIN_TIMEOUT / 60)) min. It is probably waiting at the unlock prompt: is the Mac awake, and does 'menegroth-server-unlock --diagnose' show it as verified? (docs/troubleshooting.md). Once it joins, run the Ansible workflow."
    exit 1
    ;;
  *)
    echo "usage: image-roll.sh before | after" >&2
    exit 2
    ;;
esac
