# Troubleshooting: the server didn't come back after a reboot

The root disk is encrypted, so every reboot pauses at an unlock prompt until
the Mac unlock agent (`macos/`) or a human supplies the passphrase. This page
covers what to do when that doesn't happen automatically, including how to
unlock **safely** by hand.

The one rule that runs through all of it:

> **Only ever give the root passphrase to (a) the Mac agent's verified path or
> (b) the Hetzner web console.** Never type or pipe it into an SSH session to
> a boot node yourself. The boot node's tailnet credential sits on the
> unencrypted `/boot`, so a tailnet "boot node" can be an impostor run by
> anyone holding a copy of the disk (`docs/architecture.md` D2, D11).

## 1. Which situation am I in?

Start from the alert you received (ntfy, or the heartbeat monitor):

| Alert | Meaning | Go to |
|---|---|---|
| **Menegroth server unlock REFUSED (could not verify)** | The agent can't prove the boot node is the real server, because there's no direct network path. Nothing was sent. | [§3 Safe refusal](#3-safe-refusal-could-not-verify) |
| **UNVERIFIED boot node (possible impersonation)** | A boot node answered from an address that is **not** the server's. Nothing was sent. | [§4 Possible impersonation](#4-possible-impersonation) |
| **Menegroth server unlock REFUSED** (no SERVER_IPV4) | The agent isn't configured with the server's address, so it never unlocks. | [§5 Agent not configured](#5-agent-not-configured) |
| **Menegroth server unlock FAILED** | Verified, but 1Password or SSH failed. | [§6 Unlock failed](#6-unlock-failed) |
| **Menegroth server STUCK at boot** | A boot node has waited 10+ min. One of the above is usually also firing. | [§2 Diagnose](#2-diagnose-see-what-the-agent-sees), then the matching section |
| **Heartbeat monitor** says the server is down, no agent alerts | No boot node appeared at all (or the Mac was asleep/offline). | [§7 No boot node](#7-no-boot-node-at-all) |

Whatever the cause, [§8 Manual unlock via the Hetzner console](#8-manual-unlock-via-the-hetzner-console)
gets the server running again safely. Then come back and fix the cause before
the next scheduled reboot (19:00 UTC), which would hit the same problem.

## 2. Diagnose: see what the agent sees

On the Mac:

```bash
~/.local/bin/menegroth-server-unlock --diagnose
```

This is read-only: it doesn't touch 1Password, send anything, or change agent
state. Typical output:

```
SERVER_IPV4=203.0.113.10
SERVER_IPV6_NET=2001:db8:1::/64
boot node:  menegroth-server-boot (100.101.102.103) via 203.0.113.10:41641 -> verified
```

| Result | Meaning |
|---|---|
| `verified` | Direct path from the server's own address. The agent will unlock on its next run (≤ 2 min cooldown). |
| `unverified` (`via DERP(…)`, `via peer-relay(…)`, `no reply`) | No direct path, so the origin can't be proven. See §3. |
| `mismatch` | Direct path, but from a different address. See §4. |
| `unconfigured (never unlocks)` | `SERVER_IPV4` is unset. See §5. |
| `none online` | No boot node on the tailnet. See §7. |

Logs: `~/.local/state/menegroth-server-unlock/agent.log` (decisions) and
`unlock.log` (SSH errors).

## 3. Safe refusal (could not verify)

**What happened.** Before sending the passphrase, the agent pings the boot
node and requires the reply to arrive over a *direct* connection from the
server's public address. Here the connection only works through a Tailscale
relay (DERP or a peer relay), so the agent can't see where the boot node
really is. It refused, and **nothing was sent**. This is rare: the server's
outbound traffic is unrestricted, so direct connections normally form within
seconds.

**Usual causes (on the Mac's side):** a network that blocks outbound UDP
(hotel, conference, or corporate Wi-Fi), a VPN capturing traffic, or strict
double NAT.

**Fix, in order of preference:**

1. **Restore a direct path and let the agent finish.** Move the Mac to
   another network (a phone hotspot usually works) or disconnect the VPN,
   then re-run `--diagnose` until it says `verified`. The agent keeps
   retrying every 30 s and unlocks on its own.
2. **Unlock from the Hetzner console:** [§8](#8-manual-unlock-via-the-hetzner-console).

**Do not:**

- SSH to the boot node yourself and enter the passphrase.
- Change `SERVER_IPV4` to whatever `--diagnose` reports. That address comes
  from the node being verified; the trusted value comes only from Terraform
  or the Hetzner console (§5).
- Edit the agent to skip verification "just this once".

## 4. Possible impersonation

**What happened.** A tailnet node tagged `tag:boot-unlock` answered over a
direct path from an address that is **not** the server's Primary IP. The
agent sent nothing.

**First, rule out the benign case.** Are you verifying a new image on a
throwaway server (`packer/README.md`)? It has a different IP, so this alert
is expected. Confirm in the Hetzner console that a throwaway server exists
with exactly the address shown in the alert. If so, nothing is wrong; pause
the agent during such tests (`packer/README.md`).

**Otherwise, treat it as a security incident.** The most likely explanation
is that someone has a copy of the server's disk (a backup, snapshot, or the
disk itself) and is using the `/boot` credential to fish for the passphrase.
Your data is still encrypted, and the passphrase was not sent.

1. **Unlock the real server only via the console** ([§8](#8-manual-unlock-via-the-hetzner-console))
   if it is waiting at its prompt. The console is attached to the real
   machine, so an impostor on the tailnet can't intercept it.
2. **Record, then remove the rogue node.** In the Tailscale admin console →
   Machines, note the `tag:boot-unlock` node's name, IPs, and creation time
   (for later investigation), then remove it.
3. **Revoke the `tag:boot-unlock` OAuth client** (Settings → OAuth clients)
   so the leaked copy can't join again. Until a new image is built, the
   real server's boot node can't join either; unlock via the console
   meanwhile.
4. **Find the leak.** Hetzner console → project members, API tokens, and the
   lists of backups and snapshots: who could have copied the disk? Rotate the
   Hetzner API token (`/ci/HCLOUD_TOKEN`) if there's any doubt.
5. **Rotate and rebuild:** create a new `tag:boot-unlock` OAuth client, build
   a new image, and roll the server (`docs/runbooks/key-rotation.md`). Also
   rotate the root passphrase there as a precaution, since the attacker now
   holds an encrypted copy of the disk to attack offline.

## 5. Agent not configured

The agent fails closed: with no `SERVER_IPV4` it never unlocks. This is
expected between the first `terraform apply` and configuring the agent.

1. Get the server's addresses **from a trusted source**: the
   `server_ipv4` / `server_ipv6_network` outputs at the end of the Terraform
   apply log (Actions → Terraform), or Hetzner console → **Primary IPs**
   (`menegroth-server-v4`, `menegroth-server-v6`). Never use an address
   reported by a boot node or by `--diagnose`.
2. Record them on the Mac:

   ```bash
   export MENEGROTH_SERVER_IPV4=203.0.113.10
   export MENEGROTH_SERVER_IPV6_NET=2001:db8:1::/64
   cd macos && ./install.sh
   ```

3. `--diagnose` should now say `verified` for a waiting boot node.

The Primary IPs survive image rolls (`terraform apply -replace`), so this is
a one-time step unless the IPs themselves are ever recreated.

## 6. Unlock failed

Verification passed, but the unlock itself failed:

- **1Password read failed:** the `menegroth-unlock` service-account token is
  revoked or expired. Re-create it and re-run `install.sh` (`macos/README.md`
  → Rotation).
- **SSH failed:** check `unlock.log`. A `REMOTE HOST IDENTIFICATION HAS
  CHANGED` error after an image roll means the pinned dropbear host key is
  stale: clear it (`docs/runbooks/key-rotation.md` → "After any image
  roll"). Do this only after `--diagnose` shows `verified`; a host-key change
  with an unverified origin is exactly what an impostor looks like.

Meanwhile, unlock via [§8](#8-manual-unlock-via-the-hetzner-console).

## 7. No boot node at all

The heartbeat monitor reports the server down, and the agent sees no boot
node.

1. Is the Mac awake and on the tailnet? The agent only runs while it is. If
   it was asleep, it unlocks shortly after waking (verification permitting).
2. Open the Hetzner console ([§8](#8-manual-unlock-via-the-hetzner-console),
   steps 1–3) and look at the screen:
   - **Passphrase prompt:** the initramfs couldn't join the tailnet. It gives
     up after about 3 minutes and then shows the prompt. Unlock via §8, then
     investigate: is there a Tailscale outage? Was the `tag:boot-unlock`
     OAuth client revoked (§4 step 3)? The initramfs's own log isn't kept
     after boot, so reproduce on a throwaway server from the same image
     (`packer/README.md`) if the cause isn't obvious.
   - **Anything else** (kernel panic, GRUB, a login prompt): see
     `docs/runbooks/break-glass.md`.

## 8. Manual unlock via the Hetzner console

**Why this path is safe:** the Hetzner web console is an out-of-band view of
the real machine's screen and keyboard, reached through your authenticated
Hetzner account. Unlike the tailnet, nothing on the server's disk can
impersonate it. (Hetzner can see what you type there, but Hetzner already
runs the hypervisor and is inside the trust model; see `docs/architecture.md`
D2.)

1. **Use a device you trust.** Sign in at <https://console.hetzner.cloud>
   (check the address bar) with two-factor authentication.
2. **Open the right server:** your project → **menegroth-server**. Confirm its
   public IPv4 matches your `SERVER_IPV4` (the stable Primary IP). Click
   **Console** (`>_`).
3. **Check the screen before typing anything.** It must show the
   disk-unlock prompt for `root_crypt` (e.g.
   `Please unlock disk root_crypt:`). If the server just rebooted, the prompt
   can take up to ~3 minutes to appear while the boot node tries the
   tailnet. **If you see anything else** (a login prompt, an unfamiliar
   message, or a request for any other secret), stop: do not type the
   passphrase, and go to `docs/runbooks/break-glass.md`.
4. **Get the passphrase from 1Password:** vault `Menegroth` → item
   `luks-passphrase`. It is 40 letters and digits, chosen to be typeable.
   Prefer reading and typing it. If you copy it, paste only into the console,
   and let 1Password's automatic clipboard clearing run. Never paste it
   into chat, notes, or a terminal. Use the Infisical recovery copy
   (`/unlock/ROOT_LUKS_KEY`) only if 1Password is unavailable, and read it in
   the Infisical web app (not via CLI arguments or shell history).
5. **Type it and press Enter.** cryptsetup allows several attempts. If a
   passphrase you're sure is right keeps failing, suspect a keyboard-layout
   mismatch between your machine and the console (e.g. `y`/`z` swapped on
   German layouts).
6. **Close the console tab.** The server finishes booting; the heartbeat
   resumes within ~15 minutes and the Mac agent's incident state clears on
   its own.
7. **Fix the cause** (sections above) before the next scheduled reboot.

Never fall back to SSH-ing into the boot node and typing the passphrase
there. Even on a throwaway test server, first prove the node's origin
(`packer/README.md`, verification step 3).
