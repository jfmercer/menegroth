# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a single personal Hetzner CX33 server running sandboxed AI agent workflows (NVIDIA NemoClaw). There is no application code and no test suite — the repo is Terraform + Packer + Ansible + shell, and "testing" means linters, `validate`, and the post-deploy checklist in `docs/verification.md`. Nothing deploys from a laptop: **all applies/builds happen in GitHub Actions**.

## Commands

Local verification (mirrors what CI runs on PRs):

```bash
# Terraform — real init needs HCP Terraform credentials; use -backend=false locally
cd terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate

# Packer — validate needs any non-empty HCLOUD_TOKEN (presence check only, no API call)
cd packer && packer init . && packer fmt -check . && \
  HCLOUD_TOKEN=dummy packer validate \
    -var root_luks_passphrase=placeholder \
    -var boot_tailscale_authkey=placeholder \
    -var 'mac_unlock_ssh_pubkey=ssh-ed25519 AAAAplaceholder ci-validate' .

# Ansible — collections install into ansible/collections/ (gitignored)
cd ansible && ansible-galaxy collection install -r requirements.yml && \
  ansible-lint && ansible-playbook site.yml --syntax-check

# Everything at once (gitleaks, terraform fmt/validate/tflint, ansible-lint, ...)
pre-commit run -a

# Bootstrap scripts (one-time; shellcheck with -x to follow sourced lib.sh)
cd scripts/bootstrap && shellcheck -x ./*.sh && ./bootstrap.sh --dry-run
```

Never run `terraform apply` or `packer build` locally. Apply happens on merge to master; Packer builds are `workflow_dispatch` only (each build boots a paid temporary server).

The one-time bootstrap is automated in `scripts/bootstrap/` (see `docs/architecture.md` D6): idempotent phase scripts (`10-onepassword` → `20-tailscale` → `30-infisical` → `40-github`) driven by `bootstrap.sh`, plus `preflight.sh` which validates the whole tenant before the first Packer build. The two public keys (`admin_ssh_public_key`, `mac_unlock_ssh_pubkey`) live in Infisical, **not** source — CI injects them as `TF_VAR_`/`PKR_VAR_`, so a local `terraform plan` needs `TF_VAR_admin_ssh_public_key` exported (`validate` does not). The only remaining source placeholder is `REPLACE_WITH_SERVER_PROJECT_ID` (the `infisical_server_project_id`) in `ansible/group_vars/all.yml`; the `validation` blocks on the two key variables (format `^ssh-`) must stay intact.

## CI model

Five path-filtered workflows in `.github/workflows/`:

- **terraform.yml** — fmt/validate/tflint + plan-as-PR-comment on PRs; auto-apply on master push. State lives in HCP Terraform (state-only backend, execution mode "Local").
- **ansible.yml** — lint + syntax check on PRs; on master push the runner joins the tailnet as an ephemeral `tag:ci` node and runs `site.yml` over Tailscale SSH (the server has zero public inbound ports).
- **packer.yml** — fmt/validate on PRs; image build only via manual dispatch.
- **zizmor.yml** / **codeql.yml** — security analysis of the workflows themselves (SARIF → Security tab); zizmor also runs as a pre-commit hook. Baseline: clean at `--persona=pedantic` — keep it that way when touching workflows.

Supply-chain rules (see `docs/architecture.md` D7): every `uses:` is pinned to a full commit SHA with the version as a trailing comment — **update actions (and all other deps) only via the weekly grouped Renovate PR, never by hand-editing a tag back in**; all checkouts set `persist-credentials: false`; `permissions:` are job-scoped with per-line comments. Renovate (`renovate.yml` + `renovate.json5`, self-hosted, token from Infisical `/ci`) replaced Dependabot and covers every ecosystem — including the regex-tracked bare pins (`tailscale_version`, `nemoclaw_*`); it never auto-merges.

Only three GitHub secrets exist (`TF_API_TOKEN`, `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`); every other credential is fetched from Infisical at run time. Until the bootstrap checklist in the README is completed, workflow runs fail at the Infisical secret-fetch step — that is expected.

## Architecture

Full rationale and decision log: `docs/architecture.md`. The layers compose in this order:

1. **Packer** (`packer/`) builds an Ubuntu 26.04 snapshot with a LUKS2-encrypted root from the Hetzner rescue system. Its initramfs embeds static tailscale binaries + dropbear (key-only, forced `cryptroot-unlock` command) so the machine can be unlocked remotely at boot.
2. **Terraform** (`terraform/`) boots the server from the newest `fde=true` snapshot. `lifecycle.ignore_changes = [image, user_data]` means new snapshots do NOT auto-replace the server — roll deliberately with `terraform apply -replace=hcloud_server.menegroth`.
3. **Ansible** (`ansible/site.yml`) provisions in strict role order: `harden` → `tailscale` → `infisical` → `luks_volume` → `nemoclaw` → `ops`. Later roles depend on earlier ones (e.g. `luks_volume` needs `/usr/local/bin/infisical-get`; `nemoclaw` asserts `/data` is mounted).
4. **Mac unlock agent** (`macos/`) — a launchd job polling every 30 s. When the server reboots, its initramfs joins the tailnet as an ephemeral `tag:boot-unlock` node; the agent detects it, reads the passphrase from 1Password, and pipes it over SSH into `cryptroot-unlock`.

### Security invariants (do not weaken)

- **Split key custody:** the `server` Infisical identity can read `/server/*` only. The root LUKS passphrase lives in 1Password (primary) and Infisical `/unlock/*` (recovery) — paths the server identity must **never** be granted. The server cannot unlock itself. On the free plan this is enforced by putting `/server` in a **separate Infisical project** (member: `server` identity) from `/ci`+`/unlock` (member: `ci` identity), since path-scoped roles are paid — see `docs/architecture.md` D8. Never add the `server` identity to the CI/unlock project.
- **Dark host:** the Hetzner firewall has no inbound rules (the `bootstrap_admin_ip_cidr` variable opens SSH only during initial buildout); ufw mirrors default-deny with `tailscale0` allowed.
- **Secrets never touch disk:** keys are streamed via stdin (`--key-file=-`), secret-bearing Ansible tasks use `no_log`, and the Mac agent materializes its SSH key only in a trap-cleaned mktemp dir.
- **Deliberate pins:** the NemoClaw installer is fetched by commit SHA (`nemoclaw_install_commit`, paired with `nemoclaw_install_tag` in `ansible/roles/nemoclaw/defaults/main.yml` — bump both together); `tailscale_version` in Packer pins the initramfs binaries.
- The `luks_volume` role refuses to format any device where `blkid` detects an existing signature — keep that guard.

### Operational couplings that are easy to miss

- Kernel updates rebuild the initramfs; `packer/files/initramfs/tailscale-hook` re-embeds the unlock path each time. After changing anything under `packer/`, the kernel-update survival test in `packer/README.md` is mandatory.
- Every image roll regenerates dropbear host keys; the Mac agent pins them in `~/.local/state/menegroth-server-unlock/known_hosts` (see `docs/runbooks/key-rotation.md`).
- Unattended-upgrade reboots are scheduled in Mac-awake hours (`unattended_reboot_time` in `ansible/group_vars/all.yml`) because a reboot only completes while an unlocker is reachable.
- Ansible templates (`*.j2`) are mostly shell scripts — keep them `set -euo pipefail` and shellcheck-clean like the existing ones.

## Conventions

- History is phase-per-commit (Phase 0–12), each leaving the system deployable; keep commits self-contained in that spirit.
- `docs/architecture.md` is a decision log (D1–D5) — record architectural changes there (with the *alternative considered*), and keep the README's build-phases list and bootstrap steps in sync.
- The Infisical secret layout is documented in `docs/architecture.md` D3/D8 — `/ci` and `/unlock` in project `menegroth` (env `prod`), `/server` in a separate server project. New secrets go in the least-privileged path; bootstrap routes `/server` writes to `INFISICAL_SERVER_PROJECT_ID` automatically (`scripts/bootstrap/lib.sh`).
