# Mac unlock agent

Automates unlocking the AI server's LUKS-encrypted root at boot. When the
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
bootstrap credential on disk (`~/.config/ai-server-unlock/op-token`, 0600,
FileVault at rest). Because service accounts work headlessly, unlocks stay
fully automatic even when the 1Password app is locked or not running.

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
- One-time 1Password setup is done by the bootstrap script
  (`scripts/bootstrap/10-onepassword.sh`): it creates the `Menegroth`
  vault, the `luks-passphrase` / `ntfy` / `unlock-ssh-key` items, and a
  read-only service account, and writes the service-account token to
  `~/.config/ai-server-unlock/op-token`. Run that before `./install.sh`.
  To do it by hand instead: create the vault + `luks-passphrase`/`ntfy` items,
  generate the key with
  `op item create --category 'SSH Key' --title unlock-ssh-key --vault Menegroth --ssh-generate-key ed25519`,
  and create a read-only service account scoped to that vault only.

## Install

```bash
cd macos && ./install.sh
```

The installer stores the service-account token (0600), prints the public key
for `packer/fde-image.pkr.hcl` (`mac_unlock_ssh_pubkey` — image rebuild
required on first setup), self-checks that all three vault items are
readable, and loads the launchd agent.

## Behavior details

- Cooldown of 120 s between attempts so a slow pivot isn't hammered.
- First connection pins the boot node's dropbear host key (`accept-new` into
  `~/.local/state/ai-server-unlock/known_hosts`); after an image rebuild,
  prune that file — an *unexpected* host-key failure deserves suspicion.
- If the Mac is asleep, the server just waits at the prompt; console
  fallback: `docs/runbooks/break-glass.md` §0.
- State/logs: `~/.local/state/ai-server-unlock/` (`agent.log`, `unlock.log`).

## Rotation & revocation

- **Service account token:** revoke at 1password.com, create a new one, then
  `rm ~/.config/ai-server-unlock/op-token && ./install.sh`.
- **Passphrase / SSH key:** edit in the 1Password app (avoid putting secret
  values on `op` command lines — argv is visible to other processes), then
  follow `docs/runbooks/key-rotation.md`.

## Uninstall

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.ai-server.unlock.plist
rm ~/Library/LaunchAgents/com.ai-server.unlock.plist ~/.local/bin/ai-server-unlock
rm ~/.config/ai-server-unlock/op-token
# then revoke the service account at 1password.com
```
