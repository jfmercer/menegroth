#!/usr/bin/env bash
# Teardown (teardown.yml, docs/architecture.md D15): what `terraform destroy`
# doesn't cover. By the time `sweep` runs, Terraform has deleted the server,
# the /data volume, the Primary IPs, the firewall, and the admin SSH key;
# `sweep` deletes everything else of menegroth's, and would also catch any of
# those that escaped the Terraform state.
#
# usage: teardown.sh preflight   before anything is deleted: fail now if a
#                                credential a later step needs is missing
#        teardown.sh unprotect   before terraform destroy: lift delete
#                                protection from menegroth's resources. The
#                                hcloud provider deletes without lifting it,
#                                and Hetzner refuses (423 protected).
#        teardown.sh sweep       delete menegroth's Hetzner resources (FDE
#                                snapshots, backups, image-test and Packer
#                                leftovers) and tailnet nodes
#        teardown.sh check       PASS/FAIL lines (scripts/verify/summary.sh)
#                                proving nothing of menegroth's is left, and
#                                INFO lines for what else the project holds
#
# "Menegroth's" is matched narrowly, so a Hetzner project or tailnet shared
# with other machines keeps them:
#   Hetzner  a name starting `menegroth-`; Packer's build server
#            `packer-fde-build`; the labels purpose=menegroth-image-test
#            (image test) and role=menegroth-server-base (FDE snapshots); an
#            image made from a `menegroth-` server (its backups).
#   tailnet  a tag:server or tag:boot-unlock node whose hostname starts with
#            `menegroth-server`: production, its boot nodes, image-test nodes.
set -euo pipefail

: "${HCLOUD_TOKEN:?}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/ci/hcloud.sh
source "$HERE/hcloud.sh"

# Deletion order: servers first, which frees the firewalls, volumes, and
# Primary IPs attached to them.
COLLECTIONS=(servers load_balancers firewalls volumes primary_ips floating_ips networks ssh_keys images)

HC_OWNED='(.name // "" | startswith("menegroth-")) or .name == "packer-fde-build"
  or .labels.purpose == "menegroth-image-test" or .labels.role == "menegroth-server-base"
  or (.created_from.name // "" | startswith("menegroth-"))'
TS_OWNED='any(.tags[]?; . == "tag:server" or . == "tag:boot-unlock")
  and (.hostname // "" | startswith("menegroth-server"))'

# items <collection> — every item; for images, only snapshots and backups
# (the rest are Hetzner's public system images).
items() {
  if [[ "$1" != images ]]; then
    hc_list "$1"
    return
  fi
  local snapshots backups
  snapshots="$(hc_list images type=snapshot)" || return 1
  backups="$(hc_list images type=backup)" || return 1
  jq -nc --argjson a "$snapshots" --argjson b "$backups" '$a + $b'
}

# rows <items-json> <jq-predicate> — "id<TAB>label<TAB>protected" per match.
rows() {
  jq -r ".[] | select($2) | [.id, (.name // .description // \"?\"), (.protection.delete // false)] | @tsv" <<<"$1"
}

wait_action() {
  local status
  for _ in $(seq 1 60); do
    status="$(hc GET "/actions/$1" | jq -r .action.status)"
    case "$status" in
      success) return 0 ;;
      error) return 1 ;;
    esac
    sleep 5
  done
  return 1
}

# lift_protection <collection> <id> — and wait for Hetzner to finish.
lift_protection() {
  local out body='{"delete": false}'
  [[ "$1" == servers ]] && body='{"delete": false, "rebuild": false}' # the API wants both alike
  out="$(hc POST "/$1/$2/actions/change_protection" "$body")" || return 1
  wait_action "$(jq -r .action.id <<<"$out")"
}

# remove <collection> <id> <label> <protected> — lift delete protection if
# set, delete, and wait for Hetzner to finish. Retries for a minute: a
# firewall stays attached for a moment after its server is deleted.
remove() {
  local out action
  if [[ "$4" == true ]]; then
    lift_protection "$1" "$2" || return 1
  fi
  for _ in $(seq 1 12); do
    if out="$(hc DELETE "/$1/$2")"; then
      action="$(jq -r '.action.id // empty' <<<"$out")"
      [[ -z "$action" ]] || wait_action "$action" || return 1
      echo "teardown: deleted $1 $3 ($2)" >&2
      return 0
    fi
    sleep 5
  done
  return 1
}

case "${1:-}" in
  preflight)
    hc GET "/servers?per_page=1" >/dev/null
    "$HERE/tailnet-devices.sh" list >/dev/null
    echo "teardown: the Hetzner token and the devices OAuth client work" >&2
    ;;

  unprotect)
    for c in "${COLLECTIONS[@]}"; do
      all="$(items "$c")"
      while IFS=$'\t' read -r id label _; do
        lift_protection "$c" "$id" ||
          { echo "::error::teardown: could not lift delete protection from $c $label ($id)"; exit 1; }
        echo "teardown: lifted delete protection from $c $label ($id)" >&2
      done < <(rows "$all" "($HC_OWNED) and .protection.delete == true")
    done
    ;;

  sweep)
    failed=0
    for c in "${COLLECTIONS[@]}"; do
      all="$(items "$c")"
      while IFS=$'\t' read -r id label protected; do
        remove "$c" "$id" "$label" "$protected" ||
          { echo "::error::teardown: could not delete $c $label ($id)"; failed=1; }
      done < <(rows "$all" "$HC_OWNED")
    done

    # The servers behind these nodes are gone now, so none can rejoin.
    devices="$("$HERE/tailnet-devices.sh" list)"
    while IFS=$'\t' read -r id name; do
      "$HERE/tailnet-devices.sh" delete "$id" ||
        { echo "::error::teardown: could not remove tailnet node $name ($id)"; failed=1; }
    done < <(jq -r ".[] | select($TS_OWNED) | [.nodeId, .name] | @tsv" <<<"$devices")
    exit "$failed"
    ;;

  check)
    failed=0
    others=0
    for c in "${COLLECTIONS[@]}"; do
      all="$(items "$c")"
      while IFS=$'\t' read -r id label _; do
        echo "FAIL  Hetzner $c: $label ($id) is still there"
        failed=1
      done < <(rows "$all" "$HC_OWNED")
      while IFS=$'\t' read -r id label _; do
        echo "INFO  Hetzner $c: $label ($id) is not menegroth's; left alone"
        others=$((others + 1))
      done < <(rows "$all" "($HC_OWNED) | not")
    done
    ((failed)) || echo "PASS  Hetzner: nothing of menegroth's is left"
    ((failed || others)) || echo "INFO  Hetzner: the project is empty"

    left="$("$HERE/tailnet-devices.sh" list | jq -r "[.[] | select($TS_OWNED) | .name] | join(\", \")")"
    if [[ -n "$left" ]]; then
      echo "FAIL  tailnet: still there: $left"
      failed=1
    else
      echo "PASS  tailnet: no menegroth-server node is left"
    fi
    exit "$failed"
    ;;

  *)
    echo "usage: teardown.sh preflight | unprotect | sweep | check" >&2
    exit 2
    ;;
esac
