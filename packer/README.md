# FDE image pipeline

Builds the Hetzner snapshot the server boots from: Ubuntu 26.04 with a
**LUKS2-encrypted root**, an unencrypted `/boot`, an initramfs that joins
the tailnet at the boot prompt so the Mac unlock agent (see `macos/`) can
deliver the passphrase, and a first-boot unit that joins the real system to
the tailnet so Ansible can reach a fresh server. Every build is tested on
a throwaway server before Terraform may use it. See `docs/architecture.md`
D2, D10, and D13 for the design and threat model.

## How it works

1. Packer boots a temporary **cpx22** into the Hetzner **rescue system**. Its
   80 GB disk sets the snapshot size, and a snapshot only restores onto an
   equal or larger disk, so the image fits CX33, CPX32, CX43, and so on.
2. `scripts/install-fde.sh` partitions the disk (BIOS-boot / 256 MiB EFI
   System Partition / 1 GiB `/boot` / LUKS2 root), debootstraps Ubuntu,
   installs kernel + grub (UEFI via the signed shim, written to the removable
   path `EFI/BOOT/BOOTX64.EFI`, plus a BIOS fallback) + cloud-init +
   `dropbear-initramfs` + the tailscale package, embeds the static tailscale
   binaries plus the boot node credential via the hooks in
   `files/initramfs/`, and installs `tailscale-firstboot.service`.
3. Packer snapshots the result with labels `fde=candidate,
   role=menegroth-server-base, commit=<sha>`. The workflow then tests it on
   a throwaway server (below). Only a passing build from master is relabeled
   `fde=true`, and Terraform selects the newest `fde=true` snapshot (D13).

At boot, servers built from this image: get DHCP networking in initramfs
(`ip=dhcp` on the kernel cmdline) → join the tailnet as an **ephemeral** node
(`menegroth-server-boot`, `tag:boot-unlock`; the CLI mints the key from the
OAuth client secret over HTTPS, hence the embedded CA roots + `resolv.conf`)
→ dropbear accepts the Mac agent's key (forced command `cryptroot-unlock`, no
forwarding) → root unlocks → the boot node logs itself out before pivoting to
the real system. On a server's **first** boot, `tailscale-firstboot` then
joins it as `menegroth-server` (`tag:server`, Tailscale SSH) and deletes its
credential.

If the tailnet join fails, boot gives up after ~3 minutes (bounded
`--timeout` + retries) and waits at the passphrase prompt — the Hetzner web
console always works as manual fallback.

## One-time prerequisites

All of these are produced by the bootstrap (README → "One-time bootstrap");
`scripts/bootstrap/preflight.sh` verifies them:

- Tailnet ACL defining `tag:server` and `tag:boot-unlock` (phase 20), and two
  **OAuth clients** (`auth_keys` scope, one tag each — never expiring auth
  keys, D10): `/ci/TS_SERVER_OAUTH_SECRET` and `/unlock/TS_BOOT_OAUTH_SECRET`.
- Root passphrase: generated **inside 1Password** (`luks-passphrase`, 40
  letters+digits so it stays typeable at the console), copied to Infisical
  `/unlock/ROOT_LUKS_KEY`.
- Mac unlock agent's SSH public key: `/unlock/MAC_UNLOCK_SSH_PUBKEY` (CI
  passes it as `PKR_VAR_mac_unlock_ssh_pubkey`; it is not in source).
- The `ci` Infisical identity reads `/ci` + `/unlock` (build-time only).
- For the image test (D13): the ACL rule `tag:ci` → `tag:boot-unlock:22`
  (phase 20) and a `devices:core` OAuth client, tags `tag:server` +
  `tag:boot-unlock`, at `/ci/TS_DEVICES_OAUTH_CLIENT_ID` + `_SECRET`.

## Building and testing

CI: run the "Packer FDE image" workflow via **workflow_dispatch** (PRs only
validate). One job builds the image on a temporary cpx22 (~15 minutes), then
tests it on a second, throwaway cpx22 (~25 minutes), then deletes both:

1. A fresh dropbear key is generated for this build and baked into the
   image next to the Mac's key; the job keeps the private half and discards
   it at the end.
2. `scripts/ci/image-test.sh` creates the throwaway from the snapshot, with
   production's cloud-init and a firewall that admits SSH from the runner's
   address only.
3. When dropbear answers, the runner checks the Mac's path: the boot node
   joined the tailnet from the throwaway's address, and dropbear answers
   over the tailnet (the runner is on it as `tag:ci`). It then sends the
   passphrase to the forced `cryptroot-unlock` over SSH to the throwaway's
   **public IPv4**, the address Hetzner assigned it. That trusts what the
   Mac agent's D11 check trusts, without needing a direct tailscale path,
   which GitHub runners don't reliably get.
4. It checks that the boot node leaves the tailnet at pivot, logs in to the
   real system with the bootstrap admin key (`/ci/SSH_PRIVATE_KEY`, which
   production's cloud-init authorizes), and runs
   `scripts/ci/image-test-system.sh` on it: it joined the tailnet as
   `menegroth-server` (`tag:server`), no failed units, root on LUKS2
   `root_crypt`, the first-boot credential deleted, `tailscale0` unmanaged by
   networkd and absent from netplan, and the **Mac's** unlock key in both
   dropbear's `authorized_keys` and the initramfs.
5. Kernel-update survival: `scripts/ci/image-test-kernel.sh` reinstalls the
   running kernel (its postinst hooks rebuild the initramfs) and checks the
   rebuilt initramfs; then the throwaway reboots, is unlocked again the same
   way, and passes step 4's checks again.
6. Cleanup always runs: the throwaway, its firewall, and its tailnet node
   are deleted (`scripts/ci/tailnet-devices.sh`). A passing build from
   master is promoted to `fde=true`; any other snapshot is deleted.

Dispatch the workflow on a PR branch to test that branch's image before
merging; it is never promoted. The Mac agent sees the throwaway's boot node
from the wrong address and refuses it (it alerts only if that lasts 5
minutes; the test unlocks within one or two), so there is nothing to pause.
When a system check fails, the test prints network diagnostics from the
throwaway before deleting it. Not covered: unlocking at the Hetzner web console, which there is no
API for (stock Ubuntu cryptsetup; `docs/troubleshooting.md` §8).

The test's one-time prerequisites are listed above. Failures name the step. The
job deletes its throwaway either way, so to investigate a boot node that
never joins, reproduce by hand (below) and read
`/run/initramfs/tailscale-up.log` after a console unlock.

Locally (no test, no promotion):

```bash
export HCLOUD_TOKEN=… PKR_VAR_root_luks_passphrase=… \
  PKR_VAR_boot_tailscale_oauth_secret=tskey-client-… \
  PKR_VAR_server_tailscale_oauth_secret=tskey-client-… \
  PKR_VAR_mac_unlock_ssh_pubkey='ssh-ed25519 …'
cd packer && packer init . && packer build .
```

A local build stays `fde=candidate`, so Terraform ignores it. CI is the
normal path (`CLAUDE.md`: Packer builds run via workflow_dispatch).

## Testing by hand (fallback)

If the automated test itself is broken, the same steps by hand: create a
server from the candidate snapshot in the Hetzner console; wait for the
`menegroth-server-boot` node; run `tailscale ping --until-direct
<boot-node-ip>` and confirm it ends `via <throwaway's public IPv4>:<port>`;
only then `ssh root@<boot-node-ip>` and type the passphrase; check what step
4 above checks; reinstall the kernel, reboot, unlock again; delete the
server and its `menegroth-server-N` tailnet node. Promote by setting the
snapshot's `fde` label to `true` (Hetzner console → Snapshots → Labels).

## Notes

- The boot OAuth client secret and tailscale binaries live inside the
  initramfs on the unencrypted `/boot`. The secret does not expire, so if
  disk compromise is ever suspected, **revoke the OAuth client**, create a
  new one, and rebuild (`docs/runbooks/key-rotation.md`); nodes it creates
  are ephemeral and tag-restricted.
- Bump `tailscale_version` deliberately via PR (Renovate groups it); the
  initramfs copy is independent of the running system's tailscale package.
- After the image changes (new credential, new tailscale version), dispatch
  the workflow from master; it rebuilds and re-tests before anything can roll.
