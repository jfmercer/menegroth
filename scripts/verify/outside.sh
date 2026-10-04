#!/usr/bin/env bash
# Verify, from outside the server (on a GitHub runner, NOT on the tailnet):
# the cloud-side facts the server can't see about itself. Read-only.
#
#   - Hetzner: the server runs, daily backups are on, its firewall is
#     attached with no inbound rules, its Primary IPs outlive it;
#   - a TCP scan of all 65535 ports of its public IPv4 finds nothing open
#     (GitHub runners have no IPv6, so IPv6 rests on the firewall check);
#   - images: a tested (fde=true) snapshot exists, and no image-test
#     leftovers (server, firewall, SSH key) linger;
#   - tailnet: only the production node carries the name, no stale
#     image-test nodes remain;
#   - the tailnet credentials baked into images are non-expiring OAuth
#     client secrets (D10).
#
# Prints PASS/FAIL/WARN/INFO lines like scripts/verify/server.sh; exits 1 on
# any FAIL.
set -uo pipefail

: "${HCLOUD_TOKEN:?}"
SERVER_NAME="${SERVER_NAME:-menegroth-server}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/hcloud.sh
source "$HERE/../ci/hcloud.sh"

fails=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf 'WARN  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }

# ---- Hetzner -----------------------------------------------------------------
server="$(hc GET "/servers?name=$SERVER_NAME" | jq -c '.servers[0] // empty')"
if [[ -z "$server" ]]; then
  fail "hetzner: no server named $SERVER_NAME"
  exit 1
fi
status="$(jq -r .status <<<"$server")"
if [[ "$status" == running ]]; then pass "hetzner: $SERVER_NAME is running"; else fail "hetzner: $SERVER_NAME is $status"; fi

if [[ "$(jq -r '.backup_window // empty' <<<"$server")" != "" ]]; then
  pass "hetzner: daily backups enabled (window $(jq -r .backup_window <<<"$server") UTC)"
else
  fail "hetzner: daily backups are OFF (terraform/server.tf sets backups = true)"
fi

fw_ids="$(jq -r '[.public_net.firewalls[]? | select(.status == "applied") | .id] | join(" ")' <<<"$server")"
if [[ -z "$fw_ids" ]]; then
  fail "hetzner: no firewall applied to $SERVER_NAME"
else
  for id in $fw_ids; do
    fw="$(hc GET "/firewalls/$id" | jq -c .firewall)"
    inbound="$(jq '[.rules[] | select(.direction == "in")] | length' <<<"$fw")"
    if [[ "$inbound" == 0 ]]; then
      pass "hetzner: firewall $(jq -r .name <<<"$fw") has no inbound rules (dark host, IPv4 and IPv6)"
    else
      fail "hetzner: firewall $(jq -r .name <<<"$fw") has $inbound inbound rule(s): $(jq -c '[.rules[] | select(.direction == "in") | {protocol, port, source_ips}]' <<<"$fw") (bootstrap_admin_ip_cidr left set?)"
    fi
  done
fi

for family in ipv4 ipv6; do
  pip_id="$(jq -r ".public_net.$family.id // empty" <<<"$server")"
  [[ -n "$pip_id" ]] || { fail "hetzner: no $family Primary IP"; continue; }
  pip="$(hc GET "/primary_ips/$pip_id" | jq -c .primary_ip)"
  if [[ "$(jq -r .auto_delete <<<"$pip")" == false ]]; then
    pass "hetzner: $family Primary IP $(jq -r .ip <<<"$pip") outlives the server (D11)"
  else
    fail "hetzner: $family Primary IP has auto_delete on; an image roll would change the address the Mac agent verifies"
  fi
done

# ---- Port scan -----------------------------------------------------------------
ipv4="$(jq -r .public_net.ipv4.ip <<<"$server")"
if command -v nmap >/dev/null; then
  open="$(sudo nmap -Pn -sS -p- -T4 --min-rate 3000 --max-retries 1 --open -oG - "$ipv4" 2>/dev/null |
    sed -n 's/.*Ports: //p')"
  if [[ -z "$open" ]]; then
    pass "scan: no open TCP port on $ipv4 (all 65535 probed from the internet)"
  else
    fail "scan: open on $ipv4: $open"
  fi
else
  warn "scan: nmap not installed, skipped"
fi

# ---- Images --------------------------------------------------------------------
tested="$(hc GET '/images?type=snapshot&label_selector=fde%3Dtrue,role%3Dmenegroth-server-base&sort=created:desc' |
  jq -c '[.images[] | {id, created, commit: (.labels.commit // "")}]')"
if [[ "$(jq length <<<"$tested")" -gt 0 ]]; then
  newest="$(jq -c '.[0]' <<<"$tested")"
  pass "images: $(jq length <<<"$tested") tested snapshot(s); newest $(jq -r .id <<<"$newest") from $(jq -r .created <<<"$newest")$(jq -r 'if .commit != "" then " (commit \(.commit[0:12]))" else "" end' <<<"$newest")"
  current_image="$(jq -r '.image.id // empty' <<<"$server")"
  if [[ -n "$current_image" && "$current_image" != "$(jq -r .id <<<"$newest")" ]]; then
    info "images: the server runs image $current_image; a newer tested snapshot can be rolled (docs/runbooks/key-rotation.md)"
  fi
else
  fail "images: no fde=true snapshot, so Terraform has nothing to roll onto"
fi

cutoff=$(($(date +%s) - 3 * 3600))
for kind in servers firewalls ssh_keys; do
  stale="$(hc GET "/$kind?label_selector=purpose%3Dmenegroth-image-test" | jq -r --argjson c "$cutoff" --arg k "$kind" \
    '[.[$k][] | select((.created[0:19] + "Z" | fromdateiso8601) < $c) | "\(.name) (\(.id))"] | join(", ")')"
  if [[ -z "$stale" ]]; then
    pass "images: no leftover image-test $kind"
  else
    fail "images: leftover image-test $kind: $stale (the next image test sweeps them, or delete them in the Hetzner console)"
  fi
done

# ---- Tailnet -------------------------------------------------------------------
if devices="$("$HERE/../ci/tailnet-devices.sh" list 2>/dev/null)"; then
  prod="$(jq -r --arg n "$SERVER_NAME" '[.[] | select((.tags // []) | index("tag:server")) | select(.name | startswith($n + "."))] | length' <<<"$devices")"
  if [[ "$prod" == 1 ]]; then pass "tailnet: one node holds the name $SERVER_NAME"; else fail "tailnet: $prod nodes named $SERVER_NAME"; fi
  others="$(jq -r --arg n "$SERVER_NAME" '[.[] | select((.tags // []) | index("tag:server")) | select(.name | startswith($n + ".") | not) | .name] | join(", ")' <<<"$devices")"
  if [[ -z "$others" ]]; then
    pass "tailnet: no stale tag:server nodes"
  else
    fail "tailnet: stale tag:server nodes: $others (an image test or roll that didn't clean up; remove them in the admin console)"
  fi
  boot="$(jq -r '[.[] | select((.tags // []) | index("tag:boot-unlock")) | select(.connectedToControl) | .name] | join(", ")' <<<"$devices")"
  [[ -z "$boot" ]] || info "tailnet: boot node(s) online right now: $boot (a server is at its unlock prompt)"
else
  fail "tailnet: could not list devices (TS_DEVICES_OAUTH_* missing or revoked?)"
fi

# ---- Credentials ---------------------------------------------------------------
for var in TS_SERVER_OAUTH_SECRET TS_DEVICES_OAUTH_SECRET; do
  if [[ "${!var:-}" == tskey-client-* ]]; then
    pass "credentials: /ci/$var is a non-expiring OAuth client secret"
  else
    fail "credentials: /ci/$var is missing or not an OAuth client secret (tskey-client-...); auth keys expire (D10)"
  fi
done

((fails == 0))
