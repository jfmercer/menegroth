# Bootstrap checklist

One-time setup, from zero credentials to a running FDE server. Fuller narrative
in the README ("Seed credentials"); design rationale in `docs/architecture.md`
D3/D6/D8. **[you]** = manual; **[script]** = done by `scripts/bootstrap/`.

> Renovate here is **self-hosted** (a GitHub App + Infisical), **not** Mend's
> hosted app — do not install anything from mend.io.

## 0. Prerequisites [you]

1. Install the CLIs the scripts drive: `op`, `gh`, `infisical`, `jq`, `curl`,
   `openssl`, `ssh-keygen`; `hcloud` optional (preflight).
2. `gh auth login` (owner of `jfmercer/menegroth`).
3. `infisical login` as **your user**, with **write** to *both* Infisical
   projects (the script writes as you; the machine identities are read-only).
4. **Do not** `op signin` for the scripts — 1Password access is only via the
   vault-scoped service-account token below.

## 1. Seed credentials — create by hand [you]

Each is an account/token that *authenticates the automation*, so it can't be
scripted away. Everything else (LUKS keys, admin SSH key, Tailscale ACL + join
keys, ntfy topic) is **[script]**-generated — do **not** make those by hand.

| Service | Create | Seed → destination |
|---|---|---|
| **1Password** | vault `Menegroth`; two vault-scoped service accounts (below) | `MENEGROTH_OP_BOOTSTRAP_TOKEN`; `MENEGROTH_OP_UNLOCK_TOKEN` |
| **Hetzner Cloud** | Read & Write API token | `HCLOUD_TOKEN` → `/ci` |
| **Tailscale** | API access token (ACL-write + key-mint); a `tag:ci` OAuth client (`auth_keys` scope) | `TS_API_TOKEN`; `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` → `/ci` |
| **HCP Terraform** | org **`menegroth`** + workspace **`menegroth`**, Execution Mode **Local**; user/team token | `TF_API_TOKEN` (GitHub secret) |
| **Infisical** (EU) | two projects + two identities (below) | GitHub secrets + `/ci` |
| **GitHub App** (Renovate) | App with Contents+PRs+**Workflows** write, installed on the repo | `RENOVATE_APP_ID` / `RENOVATE_APP_PRIVATE_KEY` → `/ci` |

**1Password service accounts** (1password.com → Developer → Service Accounts):

```bash
op service-account create menegroth-bootstrap --vault "Menegroth:read_items,write_items"
op service-account create menegroth-unlock   --vault "Menegroth:read_items"
```
- `menegroth-bootstrap` → `MENEGROTH_OP_BOOTSTRAP_TOKEN` (revoke after — step 7).
- `menegroth-unlock` → `MENEGROTH_OP_UNLOCK_TOKEN` (standing Mac-agent cred).

**Infisical — two projects** (free-plan split custody, D8), each `prod` env:
- `menegroth` — holds `/ci` + `/unlock`; Project ID → `INFISICAL_PROJECT_ID`.
- server project (any name) — holds `/server`; Project ID →
  `INFISICAL_SERVER_PROJECT_ID`.

**Infisical — two identities** (Universal Auth; member of **only** its project,
built-in **read** role):
- `ci` → member of `menegroth` **only** → `INFISICAL_CLIENT_ID` /
  `INFISICAL_CLIENT_SECRET` (become the GitHub secrets).
- `server` → member of the server project **only**, **never** `menegroth` →
  `SERVER_IDENTITY_CLIENT_ID` / `SERVER_IDENTITY_CLIENT_SECRET`.

**GitHub App (Renovate)**: GitHub → Settings → Developer settings → GitHub Apps
→ New. Repository permissions **Contents: write, Pull requests: write,
Workflows: write**; install on `jfmercer/menegroth`; generate a private key
(PEM). App ID + key → the `/ci/RENOVATE_APP_*` secrets.

## 2. Configure the repo [you]

5. Ensure this branch is merged (or will be) to `master` — `workflow_dispatch`
   (Packer) and the push-to-master workflows only run from the default branch.
6. Set `infisical_server_project_id` in `ansible/group_vars/all.yml` to the
   server Project ID (replaces `REPLACE_WITH_SERVER_PROJECT_ID`).
7. `cd scripts/bootstrap && cp bootstrap.env.example bootstrap.env`; set
   `INFISICAL_PROJECT_ID` + `INFISICAL_SERVER_PROJECT_ID`; leave
   `TF_CLOUD_ORGANIZATION="menegroth"` (it drives the HCP org via the CI
   variable — `versions.tf` no longer hardcodes it).
8. Export the seeds (SEEDS block in `bootstrap.env.example` lists all), e.g.
   `RENOVATE_APP_PRIVATE_KEY="$(cat your-app.pem)"`.

## 3. Run bootstrap

9. **[script]** `./bootstrap.sh --dry-run` → then `./bootstrap.sh` (idempotent).
   Phases: `10-onepassword` → `20-tailscale` → `30-infisical` → `40-github`.
   Generates/stores the LUKS keys, admin SSH key, ACL + `tag:server` /
   `tag:boot-unlock` keys, ntfy topic, and the three GitHub secrets +
   `TF_CLOUD_ORGANIZATION` variable.

## 4. Mac unlock agent [you]

10. `export MENEGROTH_OP_UNLOCK_TOKEN=…` then `cd ../../macos && ./install.sh`
    (stores the token 0600 so unlocks survive Mac reboots).

## 5. Preflight

11. **[script]** `./preflight.sh` — fix any `FAIL`. A `WARN` that no `fde=true`
    snapshot exists yet is **expected** at this stage.

## 6. Build & first apply [you]

12. Dispatch the **Packer FDE image** workflow (`workflow_dispatch`) → builds the
    LUKS2-root snapshot. (A pre-snapshot `terraform apply` on the master merge
    fails with "no fde=true snapshot" — expected; re-runs green once built.)
13. Let `terraform apply` + `ansible` run on the master push; verify per
    `docs/verification.md`.

## 7. Revoke [you]

14. Revoke `menegroth-bootstrap` (1password.com → Developer → Service Accounts)
    and `unset MENEGROTH_OP_BOOTSTRAP_TOKEN`. The only standing credential is
    then the read-only `menegroth-unlock` token on the Mac.

## Invariants — do not break

- **`server` identity is never a member of the `menegroth` project.** That
  membership is the only thing stopping the server reading `/unlock` and
  unlocking its own root (D8).
- **Exactly three GitHub secrets** (`TF_API_TOKEN`, `INFISICAL_CLIENT_ID`,
  `INFISICAL_CLIENT_SECRET`); every other credential is fetched from Infisical
  at run time, incl. the Renovate App key from `/ci`.
- **1Password access only via the vault-scoped service accounts** — never a
  personal `op` session; the project touches the `Menegroth` vault and nothing
  else.
