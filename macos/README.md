# Mac unlock agent

Automates unlocking the Menegroth server's LUKS-encrypted root at boot. When the
server reboots, its initramfs appears on the tailnet as an ephemeral
`tag:boot-unlock` node; a launchd job on this Mac (every 30 s while awake)
detects it, reads the passphrase from **1Password**, and pipes it over SSH
into the server's forced `cryptroot-unlock` command. You get an ntfy
notification on every unlock and on any failure, plus an urgent alert if a
boot prompt sits unanswered for 10+ minutes.

## Secret storage model

All unlock secrets live in a dedicated 1Password vault — nothing goes in
Apple Keychain or the Passwords app:

| Vault item (`Menegroth`) | Field | Purpose |
|---|---|---|
| `luks-passphrase` | `password` | Root FDE passphrase (recovery copy: Infisical `/unlock/ROOT_LUKS_KEY`) |
| `unlock-ssh-key` | `private key` / `public key` | SSH key trusted by the initramfs dropbear (generated inside 1Password) |
| `ntfy` | `url` | Full ntfy topic URL for notifications |

The agent authenticates with a **1Password service account** that has
**read-only access to this one vault and nothing else** — service accounts
can never be granted your Private vault, so the blast radius of a stolen
token is exactly these three revocable secrets. The token itself is the one
project credential on disk (`~/.config/menegroth-server-unlock/op-token`, 0600,
FileVault at rest) — deliberately on disk so hands-free unlock survives Mac
reboots without any manual step. Because service accounts work headlessly,
unlocks stay fully automatic even when the 1Password app is locked or not
running.

The SSH private key never rests outside 1Password: at unlock time it is
materialized into a 700 tmp dir for the single `ssh -i` call and removed on
exit. The passphrase travels stdin → SSH → tailnet → `cryptroot-unlock`;
never argv, never a file, never a log. 1Password is contacted **only** when
a boot node is actually online — the routine 30 s poll makes no API calls
(also keeps you clear of service-account rate limits).

## Prerequisites

- Tailscale installed and logged in on this Mac; tailnet ACLs allow your
  device to reach `tag:boot-unlock:22`.
- 1Password CLI: `brew install 1password-cli`.
- Xcode Command Line Tools (`/usr/bin/python3` parses `tailscale status`).
- One-time 1Password setup (see the README seed steps for details):
  1. **You** create the `Menegroth` vault and two vault-scoped service
     accounts — `menegroth-bootstrap` (read+write items; revoked after
     bootstrap) and `menegroth-unlock` (read-only; this agent's identity).
     Project scripts never use a personal `op` session: everything runs as
     one of these accounts, so 1Password itself confines the project to this
     single vault (service accounts can never see your Private vault).
  2. `scripts/bootstrap/10-onepassword.sh` (as `menegroth-bootstrap`) creates
     the `luks-passphrase` / `ntfy` / `unlock-ssh-key` items.
  3. `./install.sh` stores the **`menegroth-unlock`** token 0600 at
     `~/.config/menegroth-server-unlock/op-token` (export it as
     `MENEGROTH_OP_UNLOCK_TOKEN` first, or paste it at the prompt).

## Install

```bash
export MENEGROTH_OP_UNLOCK_TOKEN=...   # menegroth-unlock token (or paste at the prompt)
# The server's stable public addresses (terraform outputs server_ipv4 /
# server_ipv6_network). Leave unset before the first apply; re-run after it.
export MENEGROTH_SERVER_IPV4=... MENEGROTH_SERVER_IPV6_NET=...
cd macos && ./install.sh
```

The installer stores the service-account token (0600), prints the unlock
key's public half (for reference — bootstrap phase 30 already stored it at
Infisical `/unlock/MAC_UNLOCK_SSH_PUBKEY`, which the Packer build embeds; a
changed key needs an image rebuild), self-checks that all three vault items are
readable, and loads the launchd agent. One-time setup: the stored token
survives Mac reboots, so there is nothing to re-run afterwards.

## Behavior details

- **Origin verification (D11).** A `tag:boot-unlock` tag alone proves
  nothing (its credential is on the unencrypted `/boot`), so before sending
  anything the agent runs `tailscale ping --until-direct` and requires the
  reply to come over a direct path from the server's own public address
  (`SERVER_IPV4` / `SERVER_IPV6_NET` in
  `~/.config/menegroth-server-unlock/config`, set by `install.sh` from the
  Terraform outputs). A relayed-only path is a **safe refusal** (alert after
  5 min, keeps retrying). A direct path from any other address is treated as
  **possible impersonation** (urgent alert once it lasts 5 min: the automated
  image test's throwaway server looks exactly like that until CI unlocks it,
  within a minute or two). Neither ever sends the passphrase,
  and with no `SERVER_IPV4` the agent never unlocks. What to do in each case:
  `docs/troubleshooting.md`.
- `menegroth-server-unlock --diagnose` prints what the agent sees and would
  decide, read-only (no 1Password, nothing sent).
- Cooldown of 120 s between attempts so a slow pivot isn't hammered.
- No dropbear host-key pinning: the host keys live on the unencrypted
  `/boot`, so a pin proves nothing (D11). The origin check authenticates the
  boot node, and the SSH session runs inside the WireGuard tunnel to it.
  Image rolls therefore need nothing on the Mac.
- If the Mac is asleep, the server just waits at the prompt; console
  fallback: `docs/troubleshooting.md` §8.
- State/logs: `~/.local/state/menegroth-server-unlock/` (`agent.log`, `unlock.log`).

## Rotation & revocation

- **Service account token:** revoke `menegroth-unlock` at 1password.com,
  create a replacement (read-only, `Menegroth` vault only), then
  `rm ~/.config/menegroth-server-unlock/op-token && ./install.sh`.
- **Passphrase / SSH key:** edit in the 1Password app (avoid putting secret
  values on `op` command lines — argv is visible to other processes), then
  follow `docs/runbooks/key-rotation.md`.

## Uninstall

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.menegroth-server.unlock.plist
rm ~/Library/LaunchAgents/com.menegroth-server.unlock.plist ~/.local/bin/menegroth-server-unlock
rm ~/.config/menegroth-server-unlock/op-token
# then revoke the service account at 1password.com
```
