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

### D2 — Encryption: LUKS2 data volume, unencrypted root

"Full disk encryption" on a cloud VPS is weaker than it sounds: the provider
can always inspect RAM (where the key lives while mounted), and an encrypted
root requires manual passphrase entry via initramfs SSH on **every** reboot,
which conflicts with unattended kernel-security reboots.

Instead: a separate Hetzner Volume is LUKS2-encrypted and mounted at `/data`.
Everything sensitive (agent workspaces, tokens cached on disk, app state)
lives there. The unlock key is fetched from Infisical at boot by a systemd
unit and never stored on the root disk.

**Honest threat model:**

- ✅ Protects against: detached/recycled volumes, volume snapshots/backups at
  rest, Hetzner disk disposal.
- ⚠️ Partial: a live-compromised hypervisor can read RAM and thus the key.
- ⚠️ The Infisical machine-identity credential on the root disk can fetch the
  key. Mitigations: the identity is scoped to `/server/*` read-only, its
  client secret is revocable in seconds, access is logged in Infisical's
  audit log, and the credential file is root-only `0600`.

### D3 — Secrets: Infisical Cloud (EU)

Self-hosting Infisical on the same server creates a bootstrap circularity (the
server needs secrets to provision the thing that serves secrets) and costs
~2 GB RAM. Infisical Cloud avoids both. Revisit self-hosting on a *separate*
box later if data sovereignty becomes a requirement.

Secret layout in the `secure-ai-server` project, `prod` environment:

```
/ci/HCLOUD_TOKEN           Hetzner API token (used by Terraform in CI)
/ci/TS_OAUTH_CLIENT_ID     Tailscale OAuth client (CI runner tailnet join)
/ci/TS_OAUTH_SECRET
/ci/SSH_PRIVATE_KEY        Ansible bootstrap key (phases 1–2 only; Tailscale SSH after)
/ci/TS_SERVER_AUTHKEY      Pre-authorized reusable auth key (tag:server) for the server's first tailnet join
/ci/SERVER_IDENTITY_CLIENT_ID      Credentials of the "server" machine identity,
/ci/SERVER_IDENTITY_CLIENT_SECRET  delivered onto the host by the infisical role
/server/DATA_VOLUME_LUKS_KEY
/server/ANTHROPIC_API_KEY  (and other LLM provider keys)
/server/NTFY_TOPIC_URL     Alerting destination
```

Two machine identities (universal auth): `ci` reads `/ci/*`, `server` reads
`/server/*`. GitHub repo secrets contain only the `ci` identity credentials
plus `TF_API_TOKEN`.

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
    "tag:server": ["autogroup:admin"],
    "tag:ci":     ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:server:*"] },
    { "action": "accept", "src": ["tag:ci"], "dst": ["tag:server:22"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:server"], "users": ["admin", "root"] },
    { "action": "accept", "src": ["tag:ci"], "dst": ["tag:server"], "users": ["admin"] }
  ]
}
```

### D5 — Agent runtime: NVIDIA NemoClaw on OpenShell

NemoClaw provides sandboxing (containerized OpenShell runtime with capability
drops and per-sandbox network policy), blueprint-driven constraints, and
routed inference. Agents never see raw API keys unless the blueprint grants
them; keys are injected from Infisical into the NemoClaw host config.

NemoClaw is an **alpha** project — its installer version is pinned
(`NEMOCLAW_INSTALL_TAG` in the `nemoclaw` role defaults) and upgrades are
deliberate, reviewed bumps, not floating `lkg`.

## Provisioning flow

1. `terraform apply` (CI) creates SSH key, firewall, server (cloud-init:
   admin user, key-only SSH, python3), and the data volume.
2. `ansible-playbook site.yml` (CI) applies roles in order:
   `harden` → `tailscale` → `infisical` → `luks_volume` → `nemoclaw` → `ops`.
3. All roles are idempotent; the playbook runs on every merge to master.

## Out of scope (for now)

- Public-facing services (webhooks/APIs) — firewall design would change.
- Self-hosted Infisical, multi-server topology, local model inference.
