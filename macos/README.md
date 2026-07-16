# Mac unlock agent

Automates unlocking the AI server's LUKS-encrypted root at boot. When the
server reboots, its initramfs appears on the tailnet as an ephemeral
`tag:boot-unlock` node; a launchd job on this Mac (every 30 s while awake)
detects it, pulls the passphrase from the macOS Keychain, and pipes it over
SSH into the server's forced `cryptroot-unlock` command. You get an ntfy
notification on every unlock and on any failure.

## Prerequisites

- Tailscale installed and logged in on this Mac; the tailnet ACLs must allow
  your device to reach `tag:boot-unlock:22`.
- Xcode Command Line Tools (`/usr/bin/python3` is used to parse
  `tailscale status --json`).
- The root passphrase (from Infisical `/unlock/ROOT_LUKS_KEY`) and the ntfy
  topic URL at hand for the installer prompts.

## Install

```bash
cd macos && ./install.sh
```

The installer: copies the script to `~/.local/bin/ai-server-unlock`,
generates the dedicated SSH keypair (`~/.ssh/ai-server-unlock`) if missing,
stores the passphrase and ntfy URL as Keychain items (`ai-server-luks`,
`ai-server-ntfy`), and loads the launchd agent.

**First install only:** put the printed *public* key into
`packer/fde-image.pkr.hcl` (`mac_unlock_ssh_pubkey`) and rebuild the image —
the server's initramfs must trust this key.

## Security properties

- The passphrase lives in the Keychain and travels stdin → SSH → tailnet →
  `cryptroot-unlock`. Never on the Hetzner disk, never in argv, never logged.
- The SSH key is passphrase-less (launchd needs it unattended) but can only
  invoke the forced unlock command on the boot node — nothing else, nowhere
  else. FileVault protects it at rest. Keep FileVault ON.
- First connection pins the boot node's dropbear host key
  (`accept-new` into `~/.local/state/ai-server-unlock/known_hosts`); a
  changed host key after an image rebuild needs that file pruned — and an
  *unexpected* host-key failure deserves suspicion, not a shrug.

## Behavior details

- Cooldown of 120 s between attempts so a slow pivot isn't hammered.
- If the boot node is online but the unlock keeps failing (or the Mac was
  asleep), the server just waits at the prompt — nothing times out. Console
  fallback: `docs/runbooks/break-glass.md` §0.
- State/logs: `~/.local/state/ai-server-unlock/` (`agent.log`, `unlock.log`).

## Uninstall

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.ai-server.unlock.plist
rm ~/Library/LaunchAgents/com.ai-server.unlock.plist ~/.local/bin/ai-server-unlock
security delete-generic-password -s ai-server-luks
security delete-generic-password -s ai-server-ntfy
```
