#!/usr/bin/env bash
# Ansible drift: run site.yml in check mode against the server and report
# every task that WOULD change something. On a converged server that is
# nothing: a change means the server drifted from the repo, or a task isn't
# idempotent. Check mode changes nothing (read-only probes are marked
# check_mode: false so later tasks can use their results).
#
# Runs from ansible/ with the provision job's environment (verify.yml).
# Prints PASS/FAIL lines like the other verify scripts; exits 1 on FAIL.
set -uo pipefail

log="${RUNNER_TEMP:-/tmp}/ansible-drift.log"
uv run --frozen ansible-playbook site.yml --check >"$log" 2>&1
rc=$?

recap="$(sed -n '/^PLAY RECAP/,$p' "$log" | grep -E '^[a-z0-9-]+ +:' | head -n1)"
if [[ -z "$recap" ]]; then
  printf 'FAIL  ansible: the check-mode run did not finish (exit %s): %s\n' "$rc" "$(tail -n 5 "$log" | tr '\n' ' ')"
  exit 1
fi
field() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" <<<"$recap"; }
changed="$(field changed)"
failed="$(field failed)"
unreachable="$(field unreachable)"

fails=0
if [[ "$unreachable" == 0 && "$failed" == 0 ]]; then
  printf 'PASS  ansible: check mode ran cleanly (%s)\n' "$(tr -s ' ' <<<"$recap")"
else
  printf 'FAIL  ansible: check mode had %s failed / %s unreachable host(s); see the job log\n' "$failed" "$unreachable"
  fails=1
fi
if [[ "$changed" == 0 ]]; then
  echo "PASS  ansible: no drift, every task is already satisfied"
else
  # Name the tasks: the last "TASK [...]" header before each "changed:" line.
  awk '/^TASK \[/ {task = $0; sub(/^TASK \[/, "", task); sub(/\] \**$/, "", task)}
       /^changed: / {print "FAIL  ansible drift: " task}' "$log"
  fails=1
fi
exit "$fails"
