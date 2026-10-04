#!/bin/bash
# Unit tests for the teardown's sweep and check (scripts/ci/teardown.sh): the
# real script, run against a stub curl that plays the Hetzner Cloud and
# Tailscale APIs over fixture files. The fixtures model a Hetzner project and
# tailnet shared with someone else's machines, so the tests prove what the
# teardown deletes and, just as much, what it leaves alone.
# Runs on macOS (bash 3.2) and in CI on Linux (shellcheck.yml).
#
# usage: scripts/ci/tests/teardown-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEARDOWN="$HERE/../teardown.sh"

failures=0
tests=0
ok() { tests=$((tests + 1)); printf 'ok %d - %s\n' "$tests" "$1"; }
not_ok() { tests=$((tests + 1)); failures=$((failures + 1)); printf 'not ok %d - %s\n' "$tests" "$1"; [[ -z "${2:-}" ]] || printf '#   %s\n' "$2"; }
expect() { # expect <description> <command...>
  local what="$1"
  shift
  if "$@"; then ok "$what"; else not_ok "$what" "$(tail -n 5 "$T/log/out" 2>/dev/null | tr '\n' ' ')"; fi
}

# ---- Sandbox: fixtures, and stubs first on PATH ------------------------------
setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/teardown-test.XXXXXX")"
  mkdir -p "$T/bin" "$T/hz" "$T/ts" "$T/fix" "$T/log"
  : >"$T/log/deleted"
  : >"$T/log/unprotected"

  # curl: the Hetzner API (pages of two, so paging is exercised) and the
  # Tailscale API. Deletes edit the fixtures and are logged.
  cat >"$T/bin/curl" <<'EOF'
#!/bin/bash
method=GET url="" wfmt=""
while (($#)); do
  case "$1" in
    -X) method="$2"; shift ;;
    -w) wfmt="$2"; shift ;;
    -H | -d | --data-binary) shift ;;
    -K-) cat >/dev/null ;; # the token, as a curl config on stdin
    --data-urlencode) cat >/dev/null; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
respond() { # respond <http-code> <body>, in whichever form the caller's -w asks for
  case "$wfmt" in
    '\n%{http_code}') printf '%s\n%s' "$2" "$1" ;;
    '%{stderr}%{http_code}') printf '%s' "$2"; printf '%s' "$1" >&2 ;;
    *) printf '%s' "$2" ;;
  esac
}
edit() { jq "$2" "$1" >"$1.new" && mv "$1.new" "$1"; }

case "$url" in
  https://api.tailscale.com/api/v2/oauth/token) respond 200 '{"access_token": "tok"}' ;;
  https://api.tailscale.com/api/v2/tailnet/-/devices*)
    respond 200 "$(jq -c '{devices: .}' "$TS/devices.json")" ;;
  https://api.tailscale.com/api/v2/device/*)
    id="${url##*/}"
    edit "$TS/devices.json" "map(select(.nodeId != \"$id\"))"
    echo "device $id" >>"$LOG/deleted"
    respond 200 '' ;;
  https://api.hetzner.cloud/v1/*)
    path="${url#https://api.hetzner.cloud/v1/}"
    query=""
    [[ "$path" == *\?* ]] && { query="${path#*\?}"; path="${path%%\?*}"; }
    IFS=/ read -r coll id sub action <<<"$path"
    file="$HZ/$coll.json"
    case "$method $coll" in
      "GET actions") respond 200 "{\"action\": {\"id\": $id, \"status\": \"success\"}}" ;;
      GET*)
        page="$(sed -n 's/.*[&?]*page=\([0-9]*\).*/\1/p' <<<"$query")"
        type="$(sed -n 's/.*type=\([a-z]*\).*/\1/p' <<<"$query")"
        respond 200 "$(jq -c --arg c "$coll" --arg t "$type" --argjson p "${page:-1}" '
          [.[] | select($t == "" or .type == $t)] as $all
          | {($c): $all[($p - 1) * 2:$p * 2],
             meta: {pagination: {next_page: (if $p * 2 < ($all | length) then $p + 1 else null end)}}}' "$file")" ;;
      POST*)
        [[ "$sub/$action" == actions/change_protection ]] || { respond 400 '{"error": {"code": "bad_request"}}'; exit 0; }
        edit "$file" "map(if .id == $id then .protection.delete = false else . end)"
        echo "$coll $id" >>"$LOG/unprotected"
        respond 201 '{"action": {"id": 7, "status": "running"}}' ;;
      DELETE*)
        if grep -qx "$coll $id" "$FIX/fail-delete" 2>/dev/null; then
          respond 500 '{"error": {"code": "server_error"}}'
        elif [[ "$(jq ".[] | select(.id == $id) | .protection.delete // false" "$file")" == true ]]; then
          respond 423 '{"error": {"code": "protected"}}'
        else
          edit "$file" "map(select(.id != $id))"
          echo "$coll $id" >>"$LOG/deleted"
          if [[ "$coll" == servers ]]; then respond 200 '{"action": {"id": 9, "status": "running"}}'; else respond 204 ''; fi
        fi ;;
    esac ;;
  *) echo "stub curl: unexpected URL $url" >&2; exit 2 ;;
esac
EOF
  printf '#!/bin/bash\n' >"$T/bin/sleep" # retries without the wait
  chmod +x "$T/bin/"*
}

# Hetzner: menegroth's (incl. a server, volume, and IPs that escaped the
# Terraform state, two of them delete-protected) beside someone else's.
fixtures_shared() {
  echo '[
    {"id": 1, "name": "menegroth-server", "labels": {}, "protection": {"delete": false, "rebuild": false}},
    {"id": 2, "name": "menegroth-image-test-777", "labels": {"purpose": "menegroth-image-test"}, "protection": {"delete": false, "rebuild": false}},
    {"id": 3, "name": "packer-fde-build", "labels": {}, "protection": {"delete": false, "rebuild": false}},
    {"id": 4, "name": "other-app", "labels": {}, "protection": {"delete": false, "rebuild": false}}]' >"$T/hz/servers.json"
  echo '[
    {"id": 11, "name": "menegroth-server-data", "protection": {"delete": true}},
    {"id": 12, "name": "other-data", "protection": {"delete": true}}]' >"$T/hz/volumes.json"
  echo '[
    {"id": 21, "name": "menegroth-server-v4", "protection": {"delete": true}},
    {"id": 22, "name": "menegroth-server-v6", "protection": {"delete": true}},
    {"id": 23, "name": "primary_ip-23", "protection": {"delete": false}}]' >"$T/hz/primary_ips.json"
  echo '[
    {"id": 31, "name": "menegroth-server-fw", "labels": {}},
    {"id": 32, "name": "fw-777", "labels": {"purpose": "menegroth-image-test"}},
    {"id": 33, "name": "other-fw", "labels": {}}]' >"$T/hz/firewalls.json"
  echo '[
    {"id": 41, "name": "menegroth-server-admin", "labels": {}},
    {"id": 42, "name": "packer-0190abcd", "labels": {}},
    {"id": 43, "name": "laptop", "labels": {}}]' >"$T/hz/ssh_keys.json"
  echo '[
    {"id": 51, "type": "snapshot", "name": null, "description": "fde-ubuntu-26.04-1", "labels": {"fde": "true", "role": "menegroth-server-base"}, "created_from": {"id": 3, "name": "packer-fde-build"}, "protection": {"delete": false}},
    {"id": 52, "type": "snapshot", "name": null, "description": "fde-ubuntu-26.04-2", "labels": {"fde": "candidate", "role": "menegroth-server-base"}, "created_from": {"id": 3, "name": "packer-fde-build"}, "protection": {"delete": false}},
    {"id": 53, "type": "backup", "name": null, "description": "menegroth-server backup", "labels": {}, "created_from": {"id": 1, "name": "menegroth-server"}, "bound_to": 1, "protection": {"delete": false}},
    {"id": 54, "type": "snapshot", "name": null, "description": "other golden image", "labels": {}, "created_from": {"id": 4, "name": "other-app"}, "protection": {"delete": false}},
    {"id": 55, "type": "backup", "name": null, "description": "other-app backup", "labels": {}, "created_from": {"id": 4, "name": "other-app"}, "bound_to": 4, "protection": {"delete": false}},
    {"id": 56, "type": "system", "name": "ubuntu-26.04", "description": "Ubuntu 26.04", "labels": {}, "created_from": null, "protection": {"delete": false}}]' >"$T/hz/images.json"
  echo '[{"id": 61, "name": "other-net", "protection": {"delete": false}}]' >"$T/hz/networks.json"
  echo '[]' >"$T/hz/load_balancers.json"
  echo '[]' >"$T/hz/floating_ips.json"
  # Tailnet, as the devices OAuth client sees it: production, its boot node,
  # a suffixed duplicate from a roll, another tag:server machine, and an
  # untagged device whose name merely starts the same way.
  echo '[
    {"nodeId": "n1", "name": "menegroth-server.tail1234.ts.net", "hostname": "menegroth-server", "tags": ["tag:server"]},
    {"nodeId": "n2", "name": "menegroth-server-boot.tail1234.ts.net", "hostname": "menegroth-server-boot", "tags": ["tag:boot-unlock"]},
    {"nodeId": "n3", "name": "menegroth-server-1.tail1234.ts.net", "hostname": "menegroth-server", "tags": ["tag:server"]},
    {"nodeId": "n4", "name": "build-box.tail1234.ts.net", "hostname": "build-box", "tags": ["tag:server"]},
    {"nodeId": "n5", "name": "menegroth-server-laptop.tail1234.ts.net", "hostname": "menegroth-server-laptop"}]' >"$T/ts/devices.json"
}

# A project that held only menegroth's.
fixtures_dedicated() {
  fixtures_shared
  local f
  for f in "$T"/hz/*.json; do
    jq '[.[] | select((.name // "" | startswith("menegroth-")) or .labels.role == "menegroth-server-base")]' "$f" >"$f.new" && mv "$f.new" "$f"
  done
}

run() { # run <subcommand> — teardown.sh against the stubs; output in log/out, exit code in log/rc
  PATH="$T/bin:$PATH" HZ="$T/hz" TS="$T/ts" FIX="$T/fix" LOG="$T/log" \
    HCLOUD_TOKEN=test-token TS_DEVICES_OAUTH_CLIENT_ID=test-id TS_DEVICES_OAUTH_SECRET=tskey-client-test \
    "$TEARDOWN" "$@" >"$T/log/out" 2>&1
  echo $? >"$T/log/rc"
}
rc_is() { [[ "$(cat "$T/log/rc")" == "$1" ]]; }
out_has() { grep -qF -- "$1" "$T/log/out"; }
lines() { grep -c -- "$1" "$T/log/out" || true; }
deleted_set() { sort "$T/log/deleted" | tr '\n' ',' ; }
expected_set() { printf '%s\n' "$@" | sort | tr '\n' ','; }

# ---- Tests -------------------------------------------------------------------

setup; fixtures_shared
run check
expect "check before the sweep fails" rc_is 1
expect "check names each of menegroth's 12 Hetzner resources" test "$(lines '^FAIL  Hetzner')" -eq 12
expect "check names the leftover tailnet nodes" out_has "FAIL  tailnet: still there: menegroth-server.tail1234.ts.net, menegroth-server-boot.tail1234.ts.net, menegroth-server-1.tail1234.ts.net"

run sweep
expect "sweep succeeds" rc_is 0
expect "sweep deletes exactly menegroth's Hetzner resources and tailnet nodes" \
  test "$(deleted_set)" == "$(expected_set 'servers 1' 'servers 2' 'servers 3' 'firewalls 31' 'firewalls 32' \
    'volumes 11' 'primary_ips 21' 'primary_ips 22' 'ssh_keys 41' 'images 51' 'images 52' 'images 53' \
    'device n1' 'device n2' 'device n3')"
expect "sweep lifts delete protection only where it must" \
  test "$(sort "$T/log/unprotected" | tr '\n' ',')" == "$(expected_set 'volumes 11' 'primary_ips 21' 'primary_ips 22')"
expect "sweep deletes the servers before what is attached to them" \
  test "$(head -n 3 "$T/log/deleted" | cut -d' ' -f1 | sort -u)" == servers
expect "sweep removes tailnet nodes only after the Hetzner resources" \
  test "$(tail -n 3 "$T/log/deleted" | cut -d' ' -f1 | sort -u)" == device

run check
expect "check after the sweep passes" rc_is 0
expect "check reports Hetzner clean" out_has "PASS  Hetzner: nothing of menegroth's is left"
expect "check reports the tailnet clean" out_has "PASS  tailnet: no menegroth-server node is left"
expect "check lists the 9 resources it left alone (not system images)" test "$(lines '^INFO  Hetzner .* left alone$')" -eq 9
expect "a shared project is not reported empty" test "$(lines 'the project is empty')" -eq 0

: >"$T/log/deleted"
run sweep
expect "a second sweep succeeds" rc_is 0
expect "a second sweep deletes nothing" test ! -s "$T/log/deleted"
rm -rf "$T"

setup; fixtures_shared
run unprotect
expect "unprotect succeeds" rc_is 0
expect "unprotect lifts delete protection from menegroth's protected resources only" \
  test "$(sort "$T/log/unprotected" | tr '\n' ',')" == "$(expected_set 'volumes 11' 'primary_ips 21' 'primary_ips 22')"
expect "unprotect deletes nothing" test ! -s "$T/log/deleted"
expect "someone else's protected volume stays protected" \
  test "$(jq '.[] | select(.id == 12) | .protection.delete' "$T/hz/volumes.json")" == true
rm -rf "$T"

setup; fixtures_dedicated
run check
expect "check doesn't call a project empty while menegroth's resources remain" test "$(lines 'the project is empty')" -eq 0
run sweep
run check
expect "a dedicated project ends up empty, and check says so" out_has "INFO  Hetzner: the project is empty"
rm -rf "$T"

setup; fixtures_shared
echo "firewalls 31" >"$T/fix/fail-delete"
run sweep
expect "a delete that keeps failing fails the sweep" rc_is 1
expect "the failure names the resource" out_has "::error::teardown: could not delete firewalls menegroth-server-fw (31)"
expect "the sweep still deletes everything else" test "$(grep -c . "$T/log/deleted")" -eq 14
rm -rf "$T"

setup; fixtures_shared
run preflight
expect "preflight passes with working credentials" rc_is 0
PATH="$T/bin:$PATH" HZ="$T/hz" TS="$T/ts" FIX="$T/fix" LOG="$T/log" HCLOUD_TOKEN=test-token \
  "$TEARDOWN" preflight >"$T/log/out" 2>&1
echo $? >"$T/log/rc"
expect "preflight fails without the devices OAuth client" rc_is 1
expect "preflight says which credential is missing" out_has "TS_DEVICES_OAUTH_CLIENT_ID"
expect "preflight deletes nothing" test ! -s "$T/log/deleted"
rm -rf "$T"

printf '1..%d\n' "$tests"
((failures == 0)) || { printf '# %d of %d failed\n' "$failures" "$tests"; exit 1; }
