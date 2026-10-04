# Teardown

Deletes all of Menegroth's infrastructure through the **Teardown** workflow
(`.github/workflows/teardown.yml`, D15). **It is irreversible.** The server,
its Hetzner backups, and the `/data` volume go with everything on them:
NemoClaw's state, agent sessions, and anything else you kept on the server.
Copy off anything you want to keep first.

## Before you dispatch

**Pause the dead-man check** (healthchecks.io, or whichever monitor
`/server/HEARTBEAT_URL` pings). Once the server is gone its pings stop, and
the monitor pages you about 45 minutes later. CI can't pause it: that needs
your monitor account.

## Run it

Actions → **Teardown** → Run workflow, on `master`. Type exactly
`destroy menegroth-server`. Or:

```bash
gh workflow run teardown.yml --ref master -f confirm='destroy menegroth-server'
```

The run takes a few minutes. Its summary ends with a PASS/FAIL table: PASS
on both the Hetzner and the tailnet lines means nothing of Menegroth's is
left. INFO lines list anything else in the Hetzner project, which the
teardown leaves alone. "The project is empty" means you can delete the
project too.

If a run fails, fix what its error names and dispatch it again. Every step
skips what an earlier run already deleted. A wrong confirmation or a running
Packer build stops the run before anything is deleted.

## What it deletes

In order:

1. **The deploy workflows are switched off:** Terraform, Ansible, Packer,
   Verify, and Renovate. Nothing can deploy, build, or probe the server
   during the teardown or rebuild it afterwards, and the daily Verify run
   won't fail forever. Shell, zizmor, and CodeQL stay on.
2. **`terraform destroy`:** the server, the `/data` volume, both Primary
   IPs (the addresses return to Hetzner's pool), the firewall, and the admin
   SSH key. Just before it, `scripts/ci/teardown.sh unprotect` lifts the
   delete protection from the volume and the IPs: Terraform doesn't.
3. **`scripts/ci/teardown.sh sweep`:** the server's daily backups, if
   Hetzner kept any; every FDE snapshot (`fde=true` and candidates);
   leftovers from the image test and from Packer; and any resource of
   Menegroth's that escaped the Terraform state. Then the server's tailnet
   nodes: `menegroth-server`, its boot nodes, and any image-test nodes.
4. **`scripts/ci/teardown.sh check`:** proves the above.

"Menegroth's" is matched narrowly, by name, label, or origin (the header of
`scripts/ci/teardown.sh` has the rules, and `scripts/ci/tests/` tests them).
A Hetzner project or tailnet shared with other machines keeps them.

## What stays

Accounts and credentials stay. They are what CI authenticates with, and
CI's least-privilege credentials can't delete them by design. Keeping them
also makes a rebuild a few clicks (below). To decommission completely,
delete them yourself:

| Where | What |
|---|---|
| Mac | the unlock agent: `macos/README.md` → Uninstall |
| healthchecks.io (or your monitor) | the dead-man check |
| Tailscale | the four OAuth clients and the API access token; the `tag:ci`, `tag:server`, and `tag:boot-unlock` tags and rules in the policy file |
| Infisical | both projects (`menegroth`, which holds the recovery copy of the root passphrase, and the server project) and the `ci` and `server` identities |
| 1Password | the `Menegroth` vault; the `menegroth-unlock` service account (and `menegroth-bootstrap`, if it still exists) |
| HCP Terraform | the `menegroth` workspace (its state is empty now) |
| GitHub | the three secrets, the repository variables, and the Renovate GitHub App |
| Hetzner | the API token, and the project once the run reports it empty |
| Anthropic | NemoClaw's API key |
| restic target | the repository, if you enabled `ops_restic_enabled` (off by default) |

## Rebuild later

If the credentials above still exist:

```bash
for wf in terraform ansible packer verify renovate; do gh workflow enable "$wf.yml"; done
gh workflow run packer.yml --ref master     # build, test, and promote an image (~45 min)
gh workflow run terraform.yml --ref master  # create the server, volume, and new Primary IPs
```

The new Primary IPs are new addresses, so point the Mac agent at them before
the server waits at its first unlock (D11). Take the addresses from the
apply's `server_ipv4` and `server_ipv6_network` outputs:

```bash
MENEGROTH_SERVER_IPV4=... MENEGROTH_SERVER_IPV6_NET=... macos/install.sh
```

Once the server is on the tailnet, run the Ansible workflow
(`gh workflow run ansible.yml --ref master`). The new `/data` volume is
blank: Ansible formats it, and NemoClaw onboards from scratch.
