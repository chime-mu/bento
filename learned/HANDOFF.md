# Handoff — starting Phase 2 in a fresh session

Written 2026-08-30, at the end of the Phase 1 session.

## Paste this into the new session

> Implement **Phase 2** of `PLAN-v1.md` in this repo (`/Users/chime/Workspace/Bento`).
>
> Read `PLAN-v1.md`, `learned/phase-0.md` and `learned/phase-1.md` in full before doing
> anything — the learned files record measured facts that contradict upstream
> documentation, and you will waste time or break things working from the official docs.
>
> The decisions table in the plan is fixed; do not re-litigate it. If a named package or
> option doesn't exist in current nixpkgs, find the current equivalent and note the
> substitution in your report and in `learned/phase-2.md`.
>
> Phase 2 runs *inside* the VM, so start with:
>   ./scripts/run-vm.sh --headless    # then: ssh -p 2222 chime@localhost
> The image already exists at artifacts/bento.qcow2. You only need the linux builder
> (./scripts/start-linux-builder.sh) if you have to rebuild the image itself — Phase 2
> should not need to.
>
> Verify the acceptance criteria yourself. Anything you cannot verify (needs the VM's
> screen, or my credentials) — list it for me as explicit manual steps at the end.
> Finish by writing `learned/phase-2.md` and committing.

## State to be aware of

**Nothing is running.** Both VMs were shut down at the end of the Phase 1 session:

| What | How to start | Needed for Phase 2? |
|---|---|---|
| bento VM | `./scripts/run-vm.sh --headless` | **yes** — Phase 2 happens inside it |
| `linux-builder` VM | `./scripts/start-linux-builder.sh` | only to rebuild the *image* |

**`artifacts/bento.qcow2` already exists** (2.7 GiB in a 60 G qcow2) and is gitignored, so
it survives across sessions. `artifacts/edk2-aarch64-vars.fd` — the fabricated EFI
variable store — persists too, and holds the boot entry written on first boot.
`./scripts/run-vm.sh --reset-vars` throws it away if it ever gets confused.

Rebuilding the image from scratch takes roughly **25 minutes** and needs the builder up.
Avoid it: Phase 2's entire point is that you don't have to.

**Everything Phase 0 put under `/etc` is untouched and still valid.** Phase 1 needed no
sudo at all.

**The committed config is one change ahead of the image — use it as your first test.**
`home/chime/default.nix` now sets the git identity to `Michael Arnoldus <chime@mu.dk>`,
but `artifacts/bento.qcow2` was built before that and still carries the old
`ma@goodmonday.io`. Rebuilding the image for a one-line change would be exactly the waste
Phase 2 exists to eliminate, so it was left for the in-VM loop to pick up. That makes a
free, zero-risk first probe of the whole Phase 2 premise:

```bash
ssh -p 2222 chime@localhost 'git config --get user.email'   # → ma@goodmonday.io (stale)
# ... get the repo into ~/bento, then nixos-rebuild switch --flake ~/bento#bento-vm ...
ssh -p 2222 chime@localhost 'git config --get user.email'   # → chime@mu.dk
```

If that flips, the fast loop works. Note the account's SSH login key in
`modules/core.nix` is deliberately a *different* identity (`ma@goodmonday.io`, the host's
`~/.ssh/id_ed25519.pub`) — it is the only non-YubiKey key available, and an agent cannot
touch a hardware key. Leave it unless you want to generate a dedicated bento key.

## The Phase 1 findings most likely to bite Phase 2

Full detail in `learned/phase-1.md`; these three have direct Phase 2 consequences.

1. **`hosts/bento-vm/hardware.nix` duplicates the disk layout on purpose, and Phase 2 is
   exactly what would break if it were "cleaned up".** The image module sets
   `fileSystems` only while building the image; `nixos-rebuild switch --flake
   ~/bento#bento-vm` evaluates the config *without* it. Delete those `mkDefault`s and the
   in-VM rebuild fails with *"The ‘fileSystems’ option does not specify your root file
   system"* — while the image still builds fine, so the mistake looks harmless until the
   first rebuild. (Verified: the standalone evaluation resolves `/` →
   `/dev/disk/by-label/nixos`, ext4, autoResize, and systemd-boot enabled.)

2. **The VM has `nixpkgs` pinned into its own store.** `flake.nix` sets
   `nix.registry.nixpkgs.flake` and `nix.nixPath` to the exact locked revision, so inside
   the VM `nix shell nixpkgs#…` and `<nixpkgs>` resolve to the same tree the image was
   built from, without a channel. The flake's *other* input (home-manager) is not pinned
   that way, so the first in-VM `nixos-rebuild` will want to fetch it — the VM needs
   working network for that. NAT via `-nic user` is already configured.

3. **`chime` is a trusted Nix user in the guest** (`trusted-users = [ "root" "@wheel" ]`)
   and has passwordless sudo, so an agent inside the VM can rebuild the OS unattended.
   That is the Phase 2 loop working as designed, not an oversight.

## Confirmed available for Phase 2

- Guest is NixOS `26.11.20260828.83199d0`, Nix 2.34.8, `aarch64`, kernel 6.18.47.
- `git` is in the guest (both system-wide and via home-manager), so cloning the repo into
  `~/bento` works. The host repo is at `/Users/chime/Workspace/Bento`; `scp -P 2222` is
  the plan's suggested first transport.
- Root filesystem is 59 G with 54 G free — plenty of room for generations.

## Open question Phase 2 should settle

The plan says to copy the repo into the VM with `scp -P 2222`, then later switch to a git
remote. Worth deciding early *which direction is authoritative*: if edits happen inside
the VM, the host repo (the one under git, with the flake.lock that built the image) needs
a way to receive them. A shared 9p/virtfs mount of the host repo is a third option QEMU
supports and would avoid two diverging copies entirely — consider it before committing to
`scp`, and record the choice in `learned/phase-2.md`.
