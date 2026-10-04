#!/bin/bash
# Unit tests for the Mac unlock agent (macos/menegroth-server-unlock.sh): the
# real script, run against stub tailscale / op / ssh / curl, through every
# decision it makes. These replace the hand drills in docs/verification.md
# (impersonation, relay-only refusal, revoked token, stuck at boot, ...).
# Runs on macOS (bash 3.2) and in CI on Linux (shellcheck.yml).
#
# usage: macos/tests/agent-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../menegroth-server-unlock.sh"
SERVER_IPV4=203.0.113.10
SERVER_IPV6_NET=2001:db8:1:2::/64
PASSPHRASE='correct horse battery staple'
NTFY_URL=https://ntfy.example/menegroth-test

failures=0
tests=0
ok() { tests=$((tests + 1)); printf 'ok %d - %s\n' "$tests" "$1"; }
not_ok() { tests=$((tests + 1)); failures=$((failures + 1)); printf 'not ok %d - %s\n' "$tests" "$1"; [[ -z "${2:-}" ]] || printf '#   %s\n' "$2"; }
expect() { # expect <description> <command...>
  local what="$1"
  shift
  if "$@"; then ok "$what"; else not_ok "$what" "$(tail -n 5 "$T/log/out" 2>/dev/null | tr '\n' ' ')"; fi
}

# ---- Sandbox: a fake HOME, and stubs first on PATH ------------------------------
setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/agent-test.XXXXXX")"
  mkdir -p "$T/bin" "$T/fix" "$T/log" "$T/tmp" "$T/home/.config/menegroth-server-unlock"
  STATE="$T/home/.local/state/menegroth-server-unlock"
  printf 'SERVER_IPV4=%s\nSERVER_IPV6_NET=%s\n' "$SERVER_IPV4" "$SERVER_IPV6_NET" >"$T/home/.config/menegroth-server-unlock/config"
  echo "ops_fake_token" >"$T/home/.config/menegroth-server-unlock/op-token"
  printf '%s' "$PASSPHRASE" >"$T/fix/passphrase"
  echo '{"Peer": {}}' >"$T/fix/status.json"

  # tailscale: status from the fixture; ping answers from fix/ping-<ip>.
  cat >"$T/bin/tailscale" <<'EOF'
#!/bin/bash
case "$1" in
  status) cat "$FIX/status.json" ;;
  ping) ip="${!#}"; [[ -f "$FIX/ping-$ip" ]] && cat "$FIX/ping-$ip"; exit 0 ;;
esac
EOF
  # op: fails if fix/op-fail exists; logs every read.
  cat >"$T/bin/op" <<'EOF'
#!/bin/bash
echo "$*" >>"$LOG/op.log"
[[ -e "$FIX/op-fail" ]] && { echo "[ERROR] service account deleted" >&2; exit 1; }
[[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] || { echo "no token" >&2; exit 1; }
case "$2" in
  *luks-passphrase*) cat "$FIX/passphrase" ;;
  *unlock-ssh-key*) echo "fake-unlock-key-material" ;;
  *ntfy*) echo "$NTFY_URL" ;;
  *) exit 1 ;;
esac
EOF
  # ssh: records its arguments, its stdin, and whether the key file existed.
  cat >"$T/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$LOG/ssh.args"
cat >"$LOG/ssh.stdin"
key=""; prev=""
for a in "$@"; do [[ "$prev" == -i ]] && key="$a"; prev="$a"; done
[[ -s "$key" ]] && echo present >"$LOG/ssh.key" || echo missing >"$LOG/ssh.key"
exit "$(cat "$FIX/ssh-rc" 2>/dev/null || echo 0)"
EOF
  # curl: records "priority|title|url" per notification.
  cat >"$T/bin/curl" <<'EOF'
#!/bin/bash
prio=""; title=""; prev=""
for a in "$@"; do
  [[ "$prev" == -H && "$a" == Priority:* ]] && prio="${a#Priority: }"
  [[ "$prev" == -H && "$a" == Title:* ]] && title="${a#Title: }"
  prev="$a"
done
echo "$prio|$title|${!#}" >>"$LOG/ntfy.log"
EOF
  chmod +x "$T/bin/"*
}
teardown() { rm -rf "$T"; }

run_agent() {
  HOME="$T/home" TMPDIR="$T/tmp" PATH="$T/bin:$PATH" FIX="$T/fix" LOG="$T/log" NTFY_URL="$NTFY_URL" \
    bash "$AGENT" "$@" >"$T/log/out" 2>&1
  echo $? >"$T/log/rc"
}

# boot_peers "<ip> <online>" ... — the tailnet as tailscale status --json sees it
boot_peers() {
  local json='{"Peer": {' sep="" spec ip online n=0
  for spec in "$@"; do
    ip="${spec% *}"
    online="${spec#* }"
    n=$((n + 1))
    json+="$sep\"node$n\": {\"HostName\": \"menegroth-server-boot\", \"Tags\": [\"tag:boot-unlock\"], \"Online\": $online, \"TailscaleIPs\": [\"$ip\"]}"
    sep=", "
  done
  echo "$json}}" >"$T/fix/status.json"
}
pong() { printf 'pong from menegroth-server-boot (%s) via %s in 12ms\n' "$1" "$2" >"$T/fix/ping-$1"; }
relay_only() { printf 'pong from menegroth-server-boot (%s) via DERP(fra) in 30ms\n' "$1" >"$T/fix/ping-$1"; }
backdate_first_seen() { mkdir -p "$STATE"; echo $(($(date +%s) - $1)) >"$STATE/first_seen"; }

sent_unlock() { [[ -f "$T/log/ssh.args" ]]; }
alerted() { grep -q "$1" "$T/log/ntfy.log" 2>/dev/null; }
alerts() { if [[ -f "$T/log/ntfy.log" ]]; then wc -l <"$T/log/ntfy.log" | tr -d ' '; else echo 0; fi; }
op_called() { [[ -s "$T/log/op.log" ]]; }
rc_is() { [[ "$(cat "$T/log/rc")" == "$1" ]]; }
not() { ! "$@"; }
keydir_left() { compgen -G "$T/tmp/menegroth-server-unlock.*" >/dev/null; }

# ---- Tests ---------------------------------------------------------------------
setup
run_agent
expect "no boot node: exits 0" rc_is 0
expect "no boot node: sends nothing" not sent_unlock
expect "no boot node: no 1Password call (the 30 s poll stays offline)" not op_called
expect "no boot node: no alert" not alerted .
teardown

setup
boot_peers "100.64.0.10 true"
pong 100.64.0.10 "$SERVER_IPV4:41641"
run_agent
expect "verified IPv4 origin: unlocks that node" grep -qx root@100.64.0.10 "$T/log/ssh.args"
expect "verified IPv4 origin: sends exactly the passphrase, no trailing newline" cmp -s "$T/fix/passphrase" "$T/log/ssh.stdin"
expect "verified IPv4 origin: the SSH key existed for the call" grep -qx present "$T/log/ssh.key"
expect "verified IPv4 origin: the key's temp dir is gone afterwards" not keydir_left
expect "verified IPv4 origin: no persistent known_hosts pin" not grep -q "$STATE/known_hosts" "$T/log/ssh.args"
expect "verified IPv4 origin: 'unlocked' notification" alerted "Menegroth server unlocked"
expect "verified IPv4 origin: incident state cleared" not test -e "$STATE/first_seen"
expect "verified IPv4 origin: ntfy URL cached for later" grep -qsx "$NTFY_URL" "$T/home/.config/menegroth-server-unlock/ntfy-url"
teardown

setup
boot_peers "100.64.0.11 true"
pong 100.64.0.11 "[2001:db8:1:2::1]:41641"
run_agent
expect "verified IPv6 origin inside SERVER_IPV6_NET: unlocks" grep -qx root@100.64.0.11 "$T/log/ssh.args"
teardown

setup
boot_peers "100.64.0.12 true"
pong 100.64.0.12 "198.51.100.7:41641"
run_agent
expect "mismatched origin: never sends the passphrase" not sent_unlock
expect "mismatched origin, within the grace period: no alert yet (image tests)" not alerted .
backdate_first_seen 400
run_agent
expect "mismatched origin past the grace period: urgent impersonation alert" alerted "urgent|Menegroth server: UNVERIFIED boot node"
expect "mismatched origin past the grace period: still sends nothing" not sent_unlock
before="$(alerts)"
run_agent
expect "mismatched origin: the alert fires once per incident" test "$(alerts)" = "$before"
teardown

setup
boot_peers "100.64.0.13 true"
relay_only 100.64.0.13
backdate_first_seen 60
run_agent
expect "relay-only path: safe refusal, nothing sent" not sent_unlock
expect "relay-only path, within the grace period: no alert" not alerted .
backdate_first_seen 400
run_agent
expect "relay-only path past the grace period: refusal alert" alerted "high|Menegroth server unlock REFUSED (could not verify)"
teardown

setup
boot_peers "100.64.0.14 true" "100.64.0.15 true"
pong 100.64.0.14 "198.51.100.7:41641"
pong 100.64.0.15 "$SERVER_IPV4:41641"
run_agent
expect "impostor and real server online together: unlocks only the verified one" grep -qx root@100.64.0.15 "$T/log/ssh.args"
teardown

setup
boot_peers "100.64.0.16 false"
pong 100.64.0.16 "$SERVER_IPV4:41641"
run_agent
expect "offline boot node: ignored" not sent_unlock
teardown

setup
printf 'SERVER_IPV4=\n' >"$T/home/.config/menegroth-server-unlock/config"
boot_peers "100.64.0.17 true"
pong 100.64.0.17 "$SERVER_IPV4:41641"
run_agent
expect "no SERVER_IPV4 configured: fails closed, sends nothing" not sent_unlock
expect "no SERVER_IPV4 configured: refusal alert" alerted "Menegroth server unlock REFUSED"
teardown

setup
echo "$NTFY_URL" >"$T/home/.config/menegroth-server-unlock/ntfy-url"
touch "$T/fix/op-fail"
boot_peers "100.64.0.18 true"
pong 100.64.0.18 "$SERVER_IPV4:41641"
run_agent
expect "revoked 1Password token: sends nothing" not sent_unlock
expect "revoked 1Password token: 'unlock FAILED' alert still arrives (cached ntfy URL)" alerted "high|Menegroth server unlock FAILED|$NTFY_URL"
teardown

setup
echo "$NTFY_URL" >"$T/home/.config/menegroth-server-unlock/ntfy-url"
rm "$T/home/.config/menegroth-server-unlock/op-token"
boot_peers "100.64.0.19 true"
pong 100.64.0.19 "$SERVER_IPV4:41641"
run_agent
expect "missing token file: sends nothing" not sent_unlock
expect "missing token file: op is never run without a token" not op_called
expect "missing token file: 'unlock BLOCKED' alert" alerted "Menegroth server unlock BLOCKED"
teardown

setup
boot_peers "100.64.0.20 true"
pong 100.64.0.20 "198.51.100.7:41641"
backdate_first_seen 700
run_agent
expect "boot prompt waiting over 10 min: urgent STUCK alert" alerted "urgent|Menegroth server STUCK at boot"
teardown

setup
boot_peers "100.64.0.21 true"
pong 100.64.0.21 "$SERVER_IPV4:41641"
mkdir -p "$STATE"
date +%s >"$STATE/last_attempt"
run_agent
expect "cooldown: no second attempt within 120 s" not sent_unlock
teardown

setup
boot_peers "100.64.0.22 true"
pong 100.64.0.22 "$SERVER_IPV4:41641"
echo 255 >"$T/fix/ssh-rc"
run_agent
expect "unlock SSH fails: 'unlock FAILED' alert" alerted "high|Menegroth server unlock FAILED"
expect "unlock SSH fails: exits non-zero" not rc_is 0
teardown

setup
boot_peers "100.64.0.23 true" "100.64.0.24 true"
pong 100.64.0.23 "$SERVER_IPV4:41641"
pong 100.64.0.24 "198.51.100.7:41641"
run_agent --diagnose
expect "--diagnose: reports the verified node" grep -q "100.64.0.23).*-> verified" "$T/log/out"
expect "--diagnose: reports the mismatched node" grep -q "100.64.0.24).*-> mismatch" "$T/log/out"
expect "--diagnose: sends nothing, reads no secrets, alerts nobody" not sent_unlock
expect "--diagnose: no 1Password call" not op_called
expect "--diagnose: leaves no incident state" not test -e "$STATE/first_seen"
teardown

printf '1..%d\n' "$tests"
if ((failures > 0)); then
  echo "# $failures of $tests failed"
  exit 1
fi
echo "# all $tests passed"
