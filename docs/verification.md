# Verification

Every check that used to be a manual checklist item now runs in CI (D13,
D14). This page says where each one runs, and lists the few that can't be
automated.

| Where | When | What it proves |
|---|---|---|
| **Verify** workflow (`verify.yml`) | daily 06:17 UTC; Mondays add an agent turn; on demand; on PRs that change the checks | the production server and its cloud setup still match the repo |
| **Packer FDE image** workflow, image test (`scripts/ci/image-test.sh`) | every image build | a new image boots, unlocks over the tailnet, and survives a kernel update, before anything can roll onto it |
| **Shell** workflow, Mac agent tests (`macos/tests/agent-test.sh`) | every PR and push touching `macos/` | the unlock agent's decisions: when it unlocks, refuses, and alerts |
| PR checks (`terraform.yml`, `ansible.yml`, `packer.yml`, `shellcheck.yml`, `zizmor.yml`) | every PR | lint, validate, plan; the pipeline itself |

A failed scheduled Verify run pushes a high-priority ntfy alert (sent
through the server, the only machine that can read the ntfy URL) and
GitHub emails you. Each job's summary page lists every check with
✅ / ❌ / ⚠️.

## Verify workflow: what it checks

**Cloud + internet view** (`scripts/verify/outside.sh`, from a runner *off*
the tailnet):

- Hetzner: the server is running, daily backups are on, its firewall is
  applied with **no inbound rules** (IPv4 and IPv6), and both Primary IPs
  have `auto_delete` off (D11).
- `nmap` of all 65535 TCP ports on the public IPv4 finds nothing open.
  GitHub runners have no IPv6, so IPv6 rests on the firewall check.
- A tested (`fde=true`) snapshot exists; no image-test server, firewall, or
  SSH key lingers.
- The tailnet has exactly one `menegroth-server` and no stale `tag:server`
  nodes.
- `/ci/TS_SERVER_OAUTH_SECRET` and `TS_DEVICES_OAUTH_SECRET` are OAuth
  client secrets, which never expire (D10). The boot secret is enforced at
  build time by Packer's variable validation.

**Server checks** (`scripts/verify/server.sh`, as root over Tailscale SSH;
expected values come from the Ansible config via `scripts/verify/expected.py`):

- Hardening: sshd refuses root and passwords; `admin`'s shell is
  `admin_shell`; unattended-upgrades installs security updates and reboots
  at `unattended_reboot_time`; fail2ban and auditd run; ufw denies inbound
  by default and has only the documented rules.
- Tailnet: Running as `menegroth-server` with `tag:server` and Tailscale
  SSH; the first-boot credential is gone.
- System: no failed units; root on LUKS2 with one keyslot.
- Secrets: `infisical-get --check` works, and the server identity
  **cannot** read `/unlock` or `/ci` (split custody, D8; output discarded).
- Data volume: `/data` is mounted from LUKS2 with one keyslot, and came up
  unattended at boot. After a boot where Ansible or a person mounted it,
  that check is a warning until the next reboot.
- Agent runtime: 4 GB swap; the `nemoclaw.slice` and user-slice memory
  caps; every container inside `nemoclaw.slice`; no port published on all
  interfaces; the installer pinned to `nemoclaw_install_commit` with its
  marker for `nemoclaw_install_tag`; agent state on `/data`; `nemoclaw
  doctor` healthy; sandbox egress: `inference.local` allowed, `example.com`
  blocked.
- Agent turn (Mondays, or on demand): one real turn answers `PONG`, in a
  scratch session that is deleted afterwards (a few cents of inference).
- Operations: the health check ran in the last 20 minutes and succeeded;
  no failed dead-man pings in 2 hours; restic's last backup is under 26 h
  old, or a warning while restic is off; dotfiles at `DOTFILES_REF` when
  configured.

**Ansible drift** (`scripts/verify/ansible-drift.sh`): `site.yml --check`
reports zero changed tasks, or names the ones that would change.

**Terraform drift:** `terraform plan -detailed-exitcode` is empty.

**On demand** (Actions → Verify → Run workflow):

- `send_test_alert`: one low-priority ntfy message, to prove alerts reach
  your phone.
- `reboot_drill`: reboots production first and proves it comes back with
  no human involved: the Mac agent unlocks it, `/data` remounts, and every
  server check passes afterwards. Needs the Mac awake; a few minutes of
  downtime. Unattended-upgrade reboots do the same in real life.
- `agent_turn`: the agent turn, any day.

## Image test: what it checks

On a throwaway server built from each new snapshot (`packer/README.md`):
the boot node joins the tailnet from the throwaway's address and dropbear
answers over the tailnet (the Mac's path); the passphrase goes only to the
throwaway's own public address; the boot node leaves at pivot; the system joins as `menegroth-server` and deletes its
first-boot credential; no failed units; root on LUKS2; `tailscale0`
unmanaged and absent from netplan; the **Mac's** key in dropbear and in the
initramfs; then a kernel reinstall rebuilds the initramfs, and the server
reboots, unlocks, and passes again. Only a passing master build becomes
`fde=true`.

## Mac agent tests: what they check

Stubbed `tailscale`, `op`, `ssh`, and `curl`, the real agent: no boot node
means no 1Password call; a verified IPv4 or IPv6 origin gets exactly the
passphrase (no newline), and the key's temp dir is removed; a mismatched
origin is never sent anything and raises the impersonation alert once,
after the 5-minute grace; relay-only is a safe refusal with an alert after
the grace; with an impostor and the real server online, only the real one
is unlocked; no `SERVER_IPV4` fails closed; a revoked token or a missing
token file still alerts (cached ntfy URL); 10 minutes at the prompt raises
STUCK; the cooldown holds; a failed SSH alerts; `--diagnose` reads nothing
and changes nothing.

## Not automated, and why

- **Typing the passphrase at the Hetzner web console** (the break-glass
  unlock, `docs/troubleshooting.md` §8). Hetzner has no API to type into
  the console. The prompt is stock Ubuntu cryptsetup, and the image test
  proves the initramfs and LUKS setup it relies on. Worth doing once, so
  you know your Hetzner login and 2FA work when you need them.
- **Rescue mode** (`docs/runbooks/break-glass.md`): same reason; it is your
  Hetzner account access being tested.
- **Whether your dead-man monitor pages you** when pings stop: that is the
  monitor's own configuration. Verify proves the pings succeed.
