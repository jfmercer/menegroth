#!/bin/bash
# Regression test for the teardown's destroy phase: real Terraform, the
# repo's real terraform/ config and locked hcloud provider, against a mock
# Hetzner API (mock_hetzner.py) that refuses to delete protected resources,
# as the real one does. It runs the destroy-phase steps of teardown.yml (after
# "terraform init", before the sweep) exactly as the workflow defines them.
#
# The first production teardown failed here: hcloud 1.69.0 deletes without
# lifting delete protection, and Hetzner answered 423 for the /data volume
# and both Primary IPs. The state below is that run's: the server gone, the
# three protected resources left. Runs on macOS and in CI (shellcheck.yml).
#
# usage: scripts/ci/tests/teardown-destroy-test.sh   (needs terraform, uv, jq)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

failures=0
tests=0
ok() { tests=$((tests + 1)); printf 'ok %d - %s\n' "$tests" "$1"; }
not_ok() { tests=$((tests + 1)); failures=$((failures + 1)); printf 'not ok %d - %s\n' "$tests" "$1"; [[ -z "${2:-}" ]] || printf '#   %s\n' "$2"; }
expect() { # expect <description> <command...>
  local what="$1"
  shift
  if "$@"; then ok "$what"; else not_ok "$what" "$(grep -hE 'Error|error|protected' "$T"/step-*.log 2>/dev/null | head -n 3 | tr '\n' ' ')"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/teardown-destroy-test.XXXXXX")"
PORT=$((20000 + RANDOM % 20000))
python3 "$HERE/mock_hetzner.py" "$PORT" "$T/requests.log" &
MOCK=$!
trap 'kill "$MOCK" 2>/dev/null; wait "$MOCK" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/v1/volumes" >/dev/null && break; sleep 0.1; done

# A working copy laid out like the checkout, with a local backend in place of
# HCP Terraform.
mkdir -p "$T/terraform"
ln -s "$REPO"/terraform/*.tf "$REPO/terraform/templates" "$T/terraform/"
cp "$REPO/terraform/.terraform.lock.hcl" "$T/terraform/"
printf 'terraform {\n  backend "local" {}\n}\n' >"$T/terraform/override.tf"
ln -s "$REPO/scripts" "$T/scripts"

export TF_IN_AUTOMATION=true TF_CLI_ARGS_destroy=-no-color HCLOUD_ENDPOINT="http://127.0.0.1:$PORT/v1"
export HCLOUD_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # the provider wants 64 characters
export TF_VAR_admin_ssh_public_key="ssh-ed25519 AAAAtest teardown-destroy-test"

state() { terraform -chdir="$T/terraform" state list; }
left() { curl -s "$HCLOUD_ENDPOINT/volumes" | jq -r '.volumes[].name'; curl -s "$HCLOUD_ENDPOINT/primary_ips" | jq -r '.primary_ips[].name'; }

# The destroy-phase steps, as JSON lines {name, dir, run}.
steps="$(cd "$REPO" && uv run --frozen python - <<'PY'
import json
import yaml

steps = yaml.safe_load(open(".github/workflows/teardown.yml"))["jobs"]["destroy"]["steps"]
names = [s.get("name") for s in steps]
for s in steps[names.index("terraform init") + 1:names.index("Delete what Terraform doesn't manage")]:
    print(json.dumps({"name": s["name"], "dir": s.get("working-directory", "."), "run": s["run"]}))
PY
)" || { echo "Bail out! could not read the steps from teardown.yml"; exit 1; }

run_steps() { # run_steps <log-prefix> — every destroy-phase step, in order; fails on the first that fails
  local n=0 step
  while IFS= read -r step; do
    n=$((n + 1))
    (cd "$T/$(jq -r .dir <<<"$step")" && bash -e -o pipefail -c "$(jq -r .run <<<"$step")") >"$T/step-$1-$n.log" 2>&1 || return 1
  done <<<"$steps"
}

terraform -chdir="$T/terraform" init -input=false -no-color >"$T/init.log" 2>&1 ||
  { echo "Bail out! terraform init failed"; cat "$T/init.log"; exit 1; }
terraform -chdir="$T/terraform" apply -input=false -auto-approve -no-color \
  -target=hcloud_volume.data -target=hcloud_primary_ip.v4 -target=hcloud_primary_ip.v6 >"$T/setup.log" 2>&1 ||
  { echo "Bail out! setting up the state failed"; tail -n 20 "$T/setup.log"; exit 1; }
[[ "$(curl -s "$HCLOUD_ENDPOINT/volumes" | jq '[.volumes[] | select(.protection.delete)] | length')" == 1 ]] ||
  { echo "Bail out! the setup left the volume unprotected"; exit 1; }

expect "the destroy-phase steps pass with the volume and Primary IPs delete-protected" run_steps first
expect "the Terraform state is empty" test -z "$(state)"
expect "Hetzner has no volume or Primary IP left" test -z "$(left)"
expect "no DELETE was refused as protected" test "$(grep -c -- '-> 423' "$T/requests.log")" -eq 0
expect "a second run, with nothing left, passes too" run_steps second

printf '1..%d\n' "$tests"
((failures == 0)) || { printf '# %d of %d failed\n' "$failures" "$tests"; exit 1; }
