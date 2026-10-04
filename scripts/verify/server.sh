#!/usr/bin/env bash
# Verify, on the production server (as root, piped over Tailscale SSH by
# .github/workflows/verify.yml): is the server still what the repo says it
# is? Read-only, apart from the opt-ins below. Expected values come from the
# Ansible config (scripts/verify/expected.py), passed as environment.
#
# Prints one line per check: PASS, FAIL, WARN (needs a look, not broken), or
# INFO. Exits 1 if anything FAILed.
#
# Opt-ins (environment): SEND_TEST_ALERT=true pushes one low-priority ntfy
# message; AGENT_TURN=true runs one agent turn in a scratch session (a few
# cents of inference) and deletes the session; CI_PROJECT_ID=<id> enables
# the key-custody check (the server identity must not read that project).
set -uo pipefail

: "${ADMIN_USER:?}" "${ADMIN_SHELL:?}" "${REBOOT_TIME:?}" "${NEMOCLAW_TAG:?}" "${NEMOCLAW_COMMIT:?}"
: "${NEMOCLAW_USER:?}" "${NEMOCLAW_UID:?}" "${NEMOCLAW_HOME:?}" "${NEMOCLAW_SANDBOX:?}"
: "${NEMOCLAW_GATEWAY_PORT:?}" "${SWAP_FILE:?}" "${SWAP_MB:?}" "${CONTAINERS_MEMORY_MAX:?}"
: "${USER_MEMORY_MAX:?}" "${DATA_MOUNT:?}" "${DATA_MAPPER:?}" "${DATA_DEVICE_GLOB:?}" "${RESTIC_ENABLED:?}"

fails=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf 'WARN  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }
check() { # check <description> <command...> — PASS/FAIL on the exit status
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
as_nemoclaw() { # login shell, so ~/.local/bin is on PATH; never reads our stdin
  sudo -iu "$NEMOCLAW_USER" env NEMOCLAW_NO_POLICY_HINT=1 NODE_NO_WARNINGS=1 "$@" </dev/null
}

# ---- Hardening ---------------------------------------------------------------
sshd_cfg="$(sshd -T 2>/dev/null)"
for want in "permitrootlogin no" "passwordauthentication no" "kbdinteractiveauthentication no"; do
  check "sshd: $want" grep -qx "$want" <<<"$sshd_cfg"
done

shell="$(getent passwd "$ADMIN_USER" | cut -d: -f7)"
if [[ "$shell" == "$ADMIN_SHELL" ]]; then
  pass "$ADMIN_USER's login shell is $ADMIN_SHELL"
else
  fail "$ADMIN_USER's login shell is '$shell', want $ADMIN_SHELL"
fi

uu="$(apt-config dump 2>/dev/null)"
check "unattended-upgrades installs security updates" grep -q 'Allowed-Origins:: ".*-security"' <<<"$uu"
check "unattended-upgrades reboots automatically" grep -q 'Unattended-Upgrade::Automatic-Reboot "true"' <<<"$uu"
check "unattended-upgrades reboot time is $REBOOT_TIME" grep -q "Unattended-Upgrade::Automatic-Reboot-Time \"$REBOOT_TIME\"" <<<"$uu"
for unit in unattended-upgrades.service apt-daily-upgrade.timer fail2ban.service auditd.service; do
  check "$unit is active" systemctl is-active --quiet "$unit"
done

ufw_status="$(ufw status verbose 2>/dev/null)"
check "ufw: active, default deny incoming" grep -q 'Default: deny (incoming)' <<<"$ufw_status"
check "ufw: tailscale0 allowed in" grep -q 'on tailscale0 .*ALLOW IN' <<<"$ufw_status"
# Only the documented rules: SSH at the host layer (firewall.yml), the tailnet
# interface, and the sandbox-to-gateway rule (D4/D5).
extra="$(sed -n '/^--/,$p' <<<"$ufw_status" | tail -n +2 | grep -v '^$' |
  grep -v -e '^22/tcp ' -e 'on tailscale0 ' -e "^172\.16\.0\.0/12 $NEMOCLAW_GATEWAY_PORT/tcp ")"
if [[ -z "$extra" ]]; then
  pass "ufw: no rules beyond the documented ones"
else
  fail "ufw: undocumented rules: $(tr -s ' ' <<<"$extra" | tr '\n' ';')"
fi

# ---- Tailnet -----------------------------------------------------------------
ts="$(tailscale status --json 2>/dev/null | python3 -c '
import json, sys
s = json.load(sys.stdin)
me = s.get("Self") or {}
print(s.get("BackendState"), me.get("HostName"), ",".join(me.get("Tags") or []))' 2>/dev/null)"
if [[ "$ts" == "Running menegroth-server "*tag:server* ]]; then
  pass "tailscale: Running as menegroth-server with tag:server"
else
  fail "tailscale: '$ts', want Running menegroth-server tag:server"
fi
check "tailscale: Tailscale SSH enabled" bash -c 'tailscale debug prefs | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get(\"RunSSH\") else 1)"'
check "first-boot tailnet credential is gone" test ! -e /etc/tailscale-firstboot/authkey

# ---- System ------------------------------------------------------------------
failed_units="$(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"
if [[ -z "${failed_units// /}" ]]; then pass "systemd: no failed units"; else fail "systemd: failed units: $failed_units"; fi

if [[ "$(findmnt -no SOURCE /)" == /dev/mapper/root_crypt ]]; then
  pass "root is on LUKS root_crypt"
  root_dev="$(cryptsetup status root_crypt | awk '$1 == "device:" {print $2}')"
  root_dump="$(cryptsetup luksDump "$root_dev")"
  check "root LUKS header is LUKS2" grep -Eq '^Version:\s+2$' <<<"$root_dump"
  slots="$(grep -Ec '^  [0-9]+: luks2' <<<"$root_dump")"
  if [[ "$slots" == 1 ]]; then pass "root LUKS has one keyslot"; else warn "root LUKS has $slots keyslots (a rotation in progress? docs/runbooks/key-rotation.md)"; fi
else
  fail "root is not on LUKS root_crypt ($(findmnt -no SOURCE /))"
fi

if [[ -e /var/run/reboot-required ]]; then
  info "reboot pending; unattended-upgrades reboots at $REBOOT_TIME UTC"
fi

# ---- Secrets ---------------------------------------------------------------
check "infisical-get --check: the server identity reads /server" /usr/local/bin/infisical-get --check

# Split key custody (D8): the server identity must not read the CI/unlock
# project. Output is discarded, so even a broken boundary leaks nothing here.
if [[ -n "${CI_PROJECT_ID:-}" ]]; then
  # shellcheck disable=SC1091
  source /etc/infisical/identity.env
  token="$(infisical login --method=universal-auth \
    --client-id="$INFISICAL_UNIVERSAL_AUTH_CLIENT_ID" \
    --client-secret="$INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" \
    --domain="$INFISICAL_API_URL" --plain --silent 2>/dev/null)"
  for path in /unlock /ci; do
    if [[ -z "$token" ]]; then
      fail "custody: could not log in as the server identity"
      break
    elif infisical secrets --token="$token" --projectId="$CI_PROJECT_ID" --env="$INFISICAL_ENV_SLUG" \
      --path="$path" --domain="$INFISICAL_API_URL" >/dev/null 2>&1; then
      fail "custody: the server identity CAN read $path in the CI/unlock project (D8 broken; remove it from that project NOW)"
    else
      pass "custody: the server identity cannot read $path"
    fi
  done
  unset token INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
else
  warn "custody: not checked (the CI project ID could not be resolved)"
fi

# ---- Encrypted data volume ---------------------------------------------------
if [[ "$(findmnt -no SOURCE "$DATA_MOUNT")" == "/dev/mapper/$DATA_MAPPER" ]]; then
  pass "$DATA_MOUNT is mounted from /dev/mapper/$DATA_MAPPER"
else
  fail "$DATA_MOUNT is not mounted from /dev/mapper/$DATA_MAPPER"
fi
vol=""
for candidate in $DATA_DEVICE_GLOB; do # the glob is meant to expand
  [[ -e "$candidate" ]] && { vol="$candidate"; break; }
done
if [[ -n "$vol" ]]; then
  vol_dump="$(cryptsetup luksDump "$vol")"
  check "data volume LUKS header is LUKS2" grep -Eq '^Version:\s+2$' <<<"$vol_dump"
  slots="$(grep -Ec '^  [0-9]+: luks2' <<<"$vol_dump")"
  if [[ "$slots" == 1 ]]; then pass "data volume LUKS has one keyslot"; else warn "data volume LUKS has $slots keyslots"; fi
else
  fail "no data volume matches $DATA_DEVICE_GLOB"
fi
# Unattended remount at boot: when did this boot first bring the volume up?
first="$(journalctl -b -u data-volume.service -o short-monotonic --no-pager 2>/dev/null |
  sed -n 's/^\[ *\([0-9]*\)\.[0-9]*\].*\(Finished\|Started\).*/\1/p' | head -n1)"
if [[ -z "$first" ]]; then
  warn "data volume: no start recorded this boot"
elif ((first <= 300)); then
  pass "data volume came up ${first}s after boot, unattended"
else
  warn "data volume first came up ${first}s after boot, so it was started by hand or by Ansible, not by the boot; the next reboot proves the automount"
fi

# ---- Agent runtime -----------------------------------------------------------
swap_bytes="$(swapon --show=NAME,SIZE --bytes --noheadings | awk -v f="$SWAP_FILE" '$1 == f {print $2}')"
if [[ -n "$swap_bytes" ]] && ((swap_bytes >= SWAP_MB * 1024 * 1024 - 1048576)); then
  pass "swap: $SWAP_FILE active ($((swap_bytes / 1048576)) MiB)"
else
  fail "swap: $SWAP_FILE not active at ${SWAP_MB} MiB (${swap_bytes:-inactive})"
fi

for slice_max in "nemoclaw.slice:$CONTAINERS_MEMORY_MAX" "user-$NEMOCLAW_UID.slice:$USER_MEMORY_MAX"; do
  slice="${slice_max%%:*}"
  want="${slice_max#*:}"
  got="$(systemctl show "$slice" -p MemoryMax --value)"
  if [[ "$got" == "$want" ]]; then pass "$slice MemoryMax=$got"; else fail "$slice MemoryMax=$got, want $want"; fi
done

uncapped=""
running=0
while read -r id; do
  [[ -n "$id" ]] || continue
  running=$((running + 1))
  [[ -d "/sys/fs/cgroup/nemoclaw.slice/docker-$id.scope" ]] || uncapped+=" ${id:0:12}"
done < <(docker ps -q --no-trunc 2>/dev/null)
if ((running == 0)); then
  warn "docker: no running containers (is the sandbox down?)"
elif [[ -z "$uncapped" ]]; then
  pass "docker: all $running running containers are in nemoclaw.slice"
else
  fail "docker: containers outside nemoclaw.slice:$uncapped"
fi
published="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0:|\[::\]:|:::' || true)"
if [[ -z "$published" ]]; then
  pass "docker: no port published on all interfaces"
else
  fail "docker: ports published on all interfaces: $published"
fi

if [[ -n "${NEMOCLAW_PROVIDER_KEY_SECRET:-}" ]]; then
  check "nemoclaw-install pins NEMOCLAW_INSTALL_REF=$NEMOCLAW_COMMIT" grep -q "NEMOCLAW_INSTALL_REF=$NEMOCLAW_COMMIT" /usr/local/bin/nemoclaw-install
  check "NemoClaw $NEMOCLAW_TAG install marker exists" test -e "/var/lib/nemoclaw-provisioned/$NEMOCLAW_TAG"
  owner="$(stat -c %U "$NEMOCLAW_HOME" 2>/dev/null)"
  if [[ "$owner" == "$NEMOCLAW_USER" && "$(findmnt -T "$NEMOCLAW_HOME" -no TARGET)" == "$DATA_MOUNT" ]]; then
    pass "agent state $NEMOCLAW_HOME is on $DATA_MOUNT, owned by $NEMOCLAW_USER ($(du -sh "$NEMOCLAW_HOME" 2>/dev/null | cut -f1))"
  else
    fail "agent state $NEMOCLAW_HOME: owner '$owner', mount $(findmnt -T "$NEMOCLAW_HOME" -no TARGET)"
  fi

  doctor="$(as_nemoclaw nemoclaw "$NEMOCLAW_SANDBOX" doctor --json 2>/dev/null | python3 -c '
import json, sys
text = sys.stdin.read()
d = json.loads(text[text.index("{"):])
bad = [c["label"] for c in d.get("checks", []) if c.get("status") == "fail"]
print(d.get("status"), ";".join(bad))' 2>/dev/null)"
  if [[ "$doctor" == "ok "* || "$doctor" == ok ]]; then
    pass "nemoclaw doctor: sandbox $NEMOCLAW_SANDBOX healthy"
  else
    fail "nemoclaw doctor: ${doctor:-no answer}"
  fi

  # Egress policy: a host outside the policy must be refused by the sandbox
  # proxy; inference.local, always routed, proves the exec path itself works.
  out="$(as_nemoclaw nemoclaw "$NEMOCLAW_SANDBOX" exec --no-tty --timeout 40 -- \
    curl -sS -m 10 -o /dev/null -w '%{http_code}' https://inference.local/v1/models 2>&1)"
  if [[ "$out" == *200 ]]; then
    pass "sandbox egress: inference.local reachable"
    out="$(as_nemoclaw nemoclaw "$NEMOCLAW_SANDBOX" exec --no-tty --timeout 40 -- \
      curl -sS -m 10 -o /dev/null -w '%{http_code}' https://example.com 2>&1)"
    rc=$?
    if ((rc != 0)) && [[ "$out" != *[23][0-9][0-9] ]]; then
      pass "sandbox egress: example.com (not in the policy) is blocked"
    else
      fail "sandbox egress: example.com is reachable from the sandbox ($out)"
    fi
  else
    fail "sandbox egress: could not run curl in the sandbox: $(tail -c 200 <<<"$out")"
  fi

  if [[ "${AGENT_TURN:-}" == true ]]; then
    session="menegroth-verify"
    reply="$(as_nemoclaw nemoclaw "$NEMOCLAW_SANDBOX" agent --agent main --session-id "$session" \
      -m 'Reply with exactly the word PONG and nothing else.' --json 2>/dev/null | python3 -c '
import json, sys
text = sys.stdin.read()
def find(node):
    if isinstance(node, dict):
        if "finalAssistantVisibleText" in node:
            return node["finalAssistantVisibleText"]
        node = list(node.values())
    if isinstance(node, list):
        for item in node:
            found = find(item)
            if found is not None:
                return found
    return None
print((find(json.loads(text[text.index("{"):])) or "").strip())' 2>/dev/null)"
    as_nemoclaw nemoclaw "$NEMOCLAW_SANDBOX" sessions delete "agent:main:explicit:$session" >/dev/null 2>&1
    if [[ "$reply" == PONG ]]; then
      pass "agent: one end-to-end turn answered PONG (scratch session deleted)"
    else
      fail "agent: end-to-end turn answered '${reply:-nothing}', want PONG"
    fi
  fi
else
  info "NemoClaw: no provider key configured, so the installer is skipped (D5)"
fi

# ---- Operations --------------------------------------------------------------
check "server-healthcheck.timer is active" systemctl is-active --quiet server-healthcheck.timer
last="$(systemctl show server-healthcheck.timer -p LastTriggerUSec --value)"
age=$(($(date +%s) - $(date -d "$last" +%s 2>/dev/null || echo 0)))
if ((age < 1200)); then pass "healthcheck ran ${age}s ago"; else fail "healthcheck last ran ${age}s ago (every 15 min expected)"; fi
hc_result="$(systemctl show server-healthcheck.service -p Result --value)"
if [[ "$hc_result" == success ]]; then pass "the last healthcheck run succeeded"; else fail "the last healthcheck run ended '$hc_result'"; fi
hb="$(journalctl -u server-healthcheck.service --since -2h --no-pager 2>/dev/null | grep -c 'heartbeat ping failed')"
if [[ "$hb" == 0 ]]; then pass "dead-man heartbeat: every ping in the last 2 h succeeded"; else fail "dead-man heartbeat: $hb failed pings in the last 2 h"; fi

if [[ "$RESTIC_ENABLED" == true ]]; then
  last_backup="$(systemctl show restic-backup.service -p ExecMainExitTimestamp --value)"
  b_age=$(($(date +%s) - $(date -d "$last_backup" +%s 2>/dev/null || echo 0)))
  if [[ "$(systemctl show restic-backup.service -p Result --value)" == success ]] && ((b_age < 26 * 3600)); then
    pass "restic: last backup of $DATA_MOUNT succeeded $((b_age / 3600)) h ago"
  else
    fail "restic: last backup failed or is older than 26 h ($last_backup)"
  fi
else
  warn "restic is off (ops_restic_enabled: false): nothing backs up $DATA_MOUNT; Hetzner's backups cover the root disk only"
fi

if [[ -n "${DOTFILES_REF:-}" ]]; then
  home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  head="$(sudo -u "$ADMIN_USER" git -C "$home/${DOTFILES_DEST:-.dotfiles}" rev-parse HEAD 2>/dev/null)"
  if [[ "$head" == "$DOTFILES_REF" && -e "$home/.local/state/menegroth-dotfiles/installed-$DOTFILES_REF" ]]; then
    pass "dotfiles at $DOTFILES_REF, installer ran"
  else
    fail "dotfiles: HEAD '${head:-none}', want $DOTFILES_REF (or the installer marker is missing)"
  fi
  check "nothing of the dotfiles installed for $NEMOCLAW_USER" test ! -e "$NEMOCLAW_HOME/${DOTFILES_DEST:-.dotfiles}"
fi

if [[ "${SEND_TEST_ALERT:-}" == true ]]; then
  if url="$(/usr/local/bin/infisical-get NTFY_TOPIC_URL 2>/dev/null)" &&
    curl -fsS -m 15 -H "Title: Menegroth verify: test alert" -H "Priority: low" -H "Tags: test_tube" \
      -d "Test notification from the Verify workflow. Nothing is wrong." "$url" >/dev/null 2>&1; then
    pass "ntfy: test alert sent; check your phone"
  else
    fail "ntfy: could not send the test alert"
  fi
fi

((fails == 0))
