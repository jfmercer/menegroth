# Architecture & Decision Log

Last updated: 2026-07-16

## Goal

A single personal server for secure AI agent workflows: agents run continuously
in sandboxes, with strong isolation from each other and from the credentials
and data they don't need. The whole system is reproducible from this repo.

## Hardware

Hetzner Cloud **CX33**: 4 shared AMD EPYC vCPUs, 8 GB RAM, 80 GB local SSD,
plus an attached Hetzner Volume for encrypted data.

RAM budget (approximate targets):

| Component | Budget |
|-----------|--------|
| Base OS + sshd + tailscaled + agents' host services | ~0.6 GB |
| Monitoring/healthcheck | ~0.1 GB |
| NemoClaw / OpenShell sandboxes | remaining ~7 GB (enforced per-sandbox limits) |

No GPU: all inference is routed to cloud APIs. Local models are out of scope.

## Decisions

### D1 — CI: GitHub Actions with HCP Terraform as a state-only backend

Terraform *and* Ansible both run in GitHub Actions, so there is one pipeline
system. HCP Terraform (free tier) stores state and provides locking; its
workspace execution mode is **Local** so it never runs plans itself.

*Alternative considered:* Terraform Cloud VCS-driven runs — rejected because
Ansible would still need GitHub Actions, leaving two pipelines to maintain.
*Fallback:* Hetzner Object Storage as an S3-compatible backend (Terraform ≥1.10
native lockfile) if we ever want to drop the HCP dependency; costs ~€5/mo.

### D2 — Encryption: true FDE — LUKS2 root + LUKS2 data volume (revised)

*(Revision 2026-07-16: the original design left root unencrypted for
unattended reboots. Requirement changed to full disk encryption on all
volumes, with the reboot problem solved by automated remote unlock.)*

**Root volume:** the server boots from a custom snapshot (built by the
`packer/` pipeline) with a LUKS2-encrypted root and unencrypted `/boot`. The
base OS tracks the latest Ubuntu LTS — currently 26.04 "Resolute Raccoon"
(`ubuntu_series = resolute`). At
boot, the initramfs joins the tailnet as an **ephemeral** node
(`menegroth-server-boot`, `tag:boot-unlock`) and runs dropbear (public-key only,
forced command `cryptroot-unlock`, no forwarding). The Mac unlock agent
(`macos/`) detects the boot node and pipes the passphrase from 1Password
over Tailscale SSH transport. The boot node logs itself out before
the pivot to the real root. Fallback: type the passphrase in the Hetzner web
console — always available, cannot be locked out.

**Data volume:** unchanged — LUKS2, unlocked at boot by `data-volume.service`
with a key fetched from Infisical (`/server/DATA_VOLUME_LUKS_KEY`). Its
Infisical machine-identity credential now rests on the encrypted root, which
closes the old "credential on plaintext disk" gap.

**Key custody:** the root passphrase lives in a dedicated 1Password vault
(`Menegroth`), read by the Mac agent via a service account scoped
read-only to that single vault (service accounts can never see the Private
vault). A recovery copy sits in Infisical under `/unlock/` — a path the
**server's own identity cannot read** (only the human/CI identities can).
The server can never unlock itself. Apple Keychain and the Passwords app
hold no project secrets; the only on-disk Mac credential is the 0600
service-account token file (kept on disk deliberately, so hands-free unlock
survives Mac reboots — an in-memory-only token was tried and rejected
because launchd's environment is cleared at reboot, silently disabling both
unlock and its ntfy alerting until manually re-provided).

**Honest threat model:**

- ✅ Protects at rest: disk images, snapshots, backups, recycled/detached
  disks, Hetzner disk disposal — for root *and* data.
- ⚠️ A live-compromised hypervisor can still read RAM (keys included). FDE on
  a cloud VM protects data at rest, not against a live host-level adversary.
- ⚠️ On unencrypted `/boot`: the initramfs contains the boot node's tailnet
  auth key. A disk thief cannot decrypt anything with it, but could
  impersonate the boot prompt until the key is revoked; tailnet ACLs restrict
  the tag to *receiving* port 22 from the user's devices only. Rotate by
  rebuilding the image (revoke old key in the admin console).
- ⚠️ Kernel updates rebuild the initramfs; the tailscale hook re-embeds the
  unlock path each time. The kernel-update survival test in `packer/README.md`
  is mandatory after image changes.
- ℹ️ Reboots complete only while an unlocker is reachable (Mac awake, or a
  human at the console). Unattended-upgrade reboots are scheduled in
  Mac-awake hours (D2b below).

**D2b — reboot orchestration:** unattended-upgrades reboots at 19:00 UTC
(configurable, chosen for Mac-awake hours). If the Mac misses it, the server
waits at the unlock prompt; the Mac agent alerts (ntfy) when a boot node is
online without a successful unlock, and unlocks as soon as it wakes.

### D3 — Secrets: Infisical Cloud (EU)

Self-hosting Infisical on the same server creates a bootstrap circularity (the
server needs secrets to provision the thing that serves secrets) and costs
~2 GB RAM. Infisical Cloud avoids both. Revisit self-hosting on a *separate*
box later if data sovereignty becomes a requirement.

Secret layout across **two** projects, `prod` environment (see D8 for why two).
The `menegroth` project (member: `ci` identity) holds `/ci` and `/unlock`; a
separate server project (member: `server` identity) holds `/server`:

```
# Project `menegroth` — read by the `ci` identity (CI workflows, by slug)
/ci/HCLOUD_TOKEN           Hetzner API token (used by Terraform in CI)
/ci/TS_OAUTH_CLIENT_ID     Tailscale OAuth client (CI runner tailnet join)
/ci/TS_OAUTH_SECRET
/ci/SSH_PRIVATE_KEY        Ansible bootstrap key (phases 1–2 only; Tailscale SSH after)
/ci/TS_SERVER_AUTHKEY      Pre-authorized reusable auth key (tag:server) for the server's first tailnet join
/ci/SERVER_IDENTITY_CLIENT_ID      Credentials of the "server" machine identity,
/ci/SERVER_IDENTITY_CLIENT_SECRET  delivered onto the host by the infisical role
/unlock/ROOT_LUKS_KEY      Root FDE passphrase (recovery copy; primary lives in
                           the Mac's 1Password vault). NOT readable by the server identity.
/unlock/MAC_UNLOCK_SSH_PUBKEY  Public half of the Mac unlock key (embedded at image build)
/unlock/TS_BOOT_AUTHKEY    Ephemeral pre-authorized tailnet key for the initramfs
                           boot node (embedded at image build time)

# Server project (separate) — read by the `server` identity only
/server/DATA_VOLUME_LUKS_KEY
/server/NTFY_TOPIC_URL     Alerting destination
                           (LLM provider keys also go under /server if/when
                           NemoClaw inference is configured — see the
                           nemoclaw role's nemoclaw_provider_key_* vars)
/server/RESTIC_REPOSITORY  (optional) restic backup target + password,
/server/RESTIC_PASSWORD    only if ops_restic_enabled
```

The `/unlock` path is readable by the CI identity (image builds) and the
human — **never** by the `server` identity: the server must not be able to
unlock itself. On the free plan this is enforced by project separation, not
path ACLs — see D8.

Two machine identities (universal auth): `ci` is a member of the `menegroth`
project (reads `/ci` + `/unlock`), `server` is a member of the server project
(reads `/server` only). GitHub repo secrets contain only the `ci` identity
credentials plus `TF_API_TOKEN`.

### D4 — Network: fully dark host

The Hetzner Cloud Firewall has **no inbound rules** (default deny) once
Tailscale is up. Tailscale needs only outbound UDP. `ufw` on the host mirrors
the default-deny inbound policy as defense in depth (allowing the `tailscale0`
interface). SSH:

- Human access: Tailscale SSH, authorized via tailnet ACLs.
- CI access: the GitHub Actions runner joins the tailnet as an ephemeral node
  tagged `tag:ci` via `tailscale/github-action`, then Ansible connects over
  the tailnet.
- Break-glass: Hetzner web console (VNC-like, works regardless of network) —
  see `docs/runbooks/break-glass.md`.

During phases 1–2 only, port 22 is open to a single admin IP so the very first
Ansible run can reach the box; phase 3 removes that rule.

#### Tailscale ACLs

Tailnet policy needed (configured in the Tailscale admin console):

```jsonc
{
  "tagOwners": {
    "tag:server":      ["autogroup:admin"],
    "tag:ci":          ["autogroup:admin"],
    "tag:boot-unlock": ["autogroup:admin"]
  },
  "acls": [
    // your devices reach the server on any port over the tailnet
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:server:*"] },
    // CI runners reach only SSH on the server
    { "action": "accept", "src": ["tag:ci"], "dst": ["tag:server:22"] },
    // your devices reach the initramfs unlock prompt; the boot node initiates
    // nothing (no rule has tag:boot-unlock as src). dropbear is ordinary SSH
    // over the tailnet, not Tailscale SSH — hence an acls port-22 rule, not an
    // ssh block entry.
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:boot-unlock:22"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:server"], "users": ["admin", "root"] },
    { "action": "accept", "src": ["tag:ci"], "dst": ["tag:server"], "users": ["admin"] }
  ]
}
```

This policy is applied by `scripts/bootstrap/20-tailscale.sh` (POST to
`/api/v2/tailnet/-/acl`), which also mints the `tag:server` and
`tag:boot-unlock` auth keys and stores them at `/ci/TS_SERVER_AUTHKEY` and
`/unlock/TS_BOOT_AUTHKEY`. The `tag:ci` OAuth client is the one Tailscale object
with no creation API, so it stays a hand-made seed credential.

### D5 — Agent runtime: NVIDIA NemoClaw on OpenShell

NemoClaw provides sandboxing (containerized OpenShell runtime with capability
drops and per-sandbox network policy), blueprint-driven constraints, and
routed inference. Agents never see raw API keys unless the blueprint grants
them; keys are injected from Infisical into the NemoClaw host config.

NemoClaw is an **alpha** project — its installer version is pinned
(`NEMOCLAW_INSTALL_TAG` in the `nemoclaw` role defaults) and upgrades are
deliberate, reviewed bumps, not floating `lkg`.

### D6 — Bootstrap automation via scripted CLIs

The one-time bootstrap is automated by `scripts/bootstrap/` — modular,
idempotent shell scripts driving `op`, `infisical`, `gh`, `openssl`, and the
Tailscale REST API (`curl`), plus `hcloud` in the preflight validator. From a
small set of hand-made **seed credentials** (the accounts/tokens that
authenticate the automation — Hetzner token, Tailscale API token + `tag:ci`
OAuth client, the two Infisical identities, HCP token, and two 1Password
**service accounts** scoped to the `Menegroth` vault), the scripts generate and
store everything else, and `preflight.sh` verifies the whole tenant before the
first Packer build.

**1Password scope containment:** project scripts never use a personal `op`
session. All access runs as one of two vault-scoped service accounts —
`menegroth-bootstrap` (read+write items; used only during bootstrap and
**revoked afterwards**; the `$MENEGROTH_OP_BOOTSTRAP_TOKEN` seed) and
`menegroth-unlock` (read-only; the Mac agent's standing credential, stored
0600 by `macos/install.sh`) — so 1Password enforces server-side that the
project can reach the `Menegroth` vault and nothing else (service accounts
structurally cannot be granted the Private vault). Preflight validates with
the unlock token itself, proving the agent's real credential works. To remove source-file edits from
the flow, the two public keys now live in Infisical (`/ci/ADMIN_SSH_PUBLIC_KEY`,
`/unlock/MAC_UNLOCK_SSH_PUBKEY`) and CI injects them as `TF_VAR_`/`PKR_VAR_`.

*Alternative considered:* declarative Terraform providers (Infisical, Tailscale,
TFE) — rejected because it would put root/LUKS material in Terraform state and
add a second state-bootstrap chicken-and-egg for a process that runs once.
*Known limits:* Infisical identity creation and the Tailscale OAuth client have
no scriptable creation path, so they remain seed steps; and the CLIs take secret
values on argv (brief process-list exposure on the operator's machine).

### D7 — Pipeline security scanning: zizmor + CodeQL, SHA-pinned supply chain

The workflows carry the repo's highest-value credentials, so they get their own
continuous analysis: **zizmor** (`zizmor.yml` + a pre-commit hook) statically
audits the workflow files (template injection, credential persistence, unpinned
actions, ...), and **CodeQL** (`codeql.yml`, `actions` query pack — the repo's
only CodeQL-supported language) adds semantic taint analysis, both uploading
SARIF to the Security tab (free: public repo). Supply-chain hardening landed
with them: every `uses:` is pinned to a **full commit SHA** (version as a
trailing comment) with grouped weekly Dependabot PRs keeping pins current —
never hand-edit a pin back to a tag — plus `persist-credentials: false` on all
checkouts and job-scoped `permissions:`. A full pipeline audit (2026-07-18)
recorded the findings, accepted risks (e.g. the Infisical whole-job-env
export), and deferred recommendations (saved-plan handoff, deployment
environments, `workflow_dispatch` re-run entry points); the report is kept
outside this public repo.

*Alternative considered:* actionlint alone — it lints workflow syntax/shell but
is not a security analyzer (no injection/secret-flow audits); zizmor + the
CodeQL actions pack cover that ground and feed the Security tab's stateful
triage. Manual review only was rejected: the tj-actions incident class is
exactly what mutable-tag pins + unreviewed workflow edits invite.

### D8 — Free-plan access isolation: two Infisical projects

The split-custody invariant (D3) requires the `server` identity to read
`/server` but **never** `/unlock`. Scoping an identity to specific secret
*paths* within one project needs Infisical RBAC / custom roles — a paid tier.
On the free plan the only access boundary is **project membership** with the
built-in roles (a member sees all of a project's paths). So the isolation is
structural: `/server` lives in a **separate project** whose only member is the
`server` identity, while `/ci` and `/unlock` stay in the `menegroth` project
whose only machine member is `ci`. Because `ci` legitimately reads both `/ci`
and `/unlock`, only one project needs splitting off, keeping it to two projects
(free tier allows three). The CI workflows are unaffected — they reference the
`menegroth` project by slug and read only `/ci`/`/unlock`; only the host's
`server`-identity project ID (`ansible/group_vars/all.yml`) points at the new
project. Bootstrap routes writes by path (`INFISICAL_SERVER_PROJECT_ID` for
`/server`, `INFISICAL_PROJECT_ID` otherwise; see `scripts/bootstrap/lib.sh`).

*Alternatives considered:* (a) a single project with a path-scoped custom role —
rejected: custom roles are Enterprise-tier, a recurring cost hard to justify for
a solo project; (b) a single project with both identities as members — rejected:
built-in roles can't stop the `server` identity from reading `/unlock`, breaking
the one invariant this whole design exists to hold.

## Provisioning flow

1. `terraform apply` (CI) creates SSH key, firewall, server (cloud-init:
   admin user, key-only SSH, python3), and the data volume.
2. `ansible-playbook site.yml` (CI) applies roles in order:
   `harden` → `tailscale` → `infisical` → `luks_volume` → `nemoclaw` → `ops`.
3. All roles are idempotent; the playbook runs on every merge to master.

## Operations

- **Backups:** Hetzner daily server backups (root disk, 7 slots, +20% server
  cost). `/data` optionally backed up nightly by restic (client-side
  encrypted) to any restic target — enable with `ops_restic_enabled: true`.
- **Monitoring:** a 15-minute systemd timer checks `/data` mount state, disk
  usage, failed units, Tailscale health, and OOM kills in the agent slice,
  and pushes to an ntfy topic only when something is wrong.
- **Updates:** unattended-upgrades with automatic reboots at 19:00 UTC
  (`unattended_reboot_time` in `ansible/group_vars/all.yml`, chosen for
  Mac-awake hours so the root can be unlocked — see D2b); the data volume
  re-unlocks itself after reboot (see D2).
- **Verification:** `docs/verification.md` is the post-deploy checklist.

## Out of scope (for now)

- Public-facing services (webhooks/APIs) — firewall design would change.
- Self-hosted Infisical, multi-server topology, local model inference.
