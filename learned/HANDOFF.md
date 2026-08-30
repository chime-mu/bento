# Handoff — starting Phase 1 in a fresh session

Written 2026-08-30, at the end of the Phase 0 session.

## Paste this into the new session

> Implement **Phase 1** of `PLAN-v1.md` in this repo (`/Users/chime/Workspace/Bento`).
>
> Read `PLAN-v1.md` and `learned/phase-0.md` in full before doing anything — phase-0
> records measured facts that contradict upstream documentation, and you will waste time
> or break things if you work from the official docs instead.
>
> The decisions table in the plan is fixed; do not re-litigate it. If a named package or
> option doesn't exist in current nixpkgs, find the current equivalent and note the
> substitution in your report and in `learned/phase-1.md`.
>
> Start by running `./scripts/start-linux-builder.sh` — the builder VM does not survive
> across sessions and Phase 1 cannot build the image without it.
>
> Verify the acceptance criteria yourself. Anything you cannot verify (needs the VM's
> screen, or my credentials) — list it for me as explicit manual steps at the end.
> Finish by writing `learned/phase-1.md` and committing.

## State to be aware of

**The `darwin.linux-builder` VM is NOT running.** It ran as a background process in the
Phase 0 session and was shut down at the end. It must be restarted:

```bash
./scripts/start-linux-builder.sh
```

No sudo is needed — Phase 0 installed a stable keypair specifically so an agent can start
it unattended. Its disk image lives at `~/.local/state/bento/builder-disk.qcow2` (20 GB)
and its keys at `~/.local/state/bento/builder-keys/`. Both are outside the repo and
persist. If the image is ever corrupted, delete it and it will be recreated on next start.

**Everything else Phase 0 set up is persistent** and survives reboots:

- `/etc/nix/nix.custom.conf` — `builders`, `builders-use-substitutes`, `extra-trusted-users`
- `/etc/ssh/ssh_config.d/100-linux-builder.conf` — `linux-builder` host on port 31022
- `/etc/nix/builder_ed25519{,.pub}` — builder credentials
- Nix and QEMU installations

## The five Phase 0 findings most likely to bite Phase 1

Full detail in `learned/phase-0.md`; these are the ones with direct Phase 1 consequences.

1. **There is no `edk2-aarch64-vars.fd` on this machine.** Homebrew ships only
   `edk2-aarch64-code.fd`. Phase 1's `run-vm.sh` must create its own writable 64 MiB vars
   pflash (`dd if=/dev/zero of=... bs=1m count=64`). Both pflash drives must be 64 MiB.
   Firmware lives at `/opt/homebrew/share/qemu/edk2-aarch64-code.fd`.

2. **Never use a cached package as a build-capability test.**
   `nix build nixpkgs#legacyPackages.aarch64-linux.hello` passes with no builder at all —
   it substitutes. Use the unsubstitutable `runCommand` probe in the README.

3. **The Nix daemon label is `systems.determinate.nix-daemon`,** not
   `org.nixos.nix-daemon`. Documentation using the latter silently does nothing here.
   User Nix settings go in `/etc/nix/nix.custom.conf`, never `nix.conf` (it gets
   overwritten on upgrade).

4. **The host QEMU has no OpenGL.** `virtio-gpu-gl-pci` does not exist in this build and
   `-display cocoa,gl=es` errors out. Phase 1 must use plain `-device virtio-gpu-pci` and
   `-display cocoa`. Do not spend time trying to enable GL — that is Phase 6 and requires
   replacing the QEMU binary entirely.

5. **macOS shell traps:** there is no `timeout(1)`; BSD `grep` does not support `\s` or
   `\b` (use `[[:space:]]`); `sudo` timestamps are per-TTY so an agent cannot reuse a
   human's cached sudo — batch all root work into one script for the human to run.

## Confirmed available for Phase 1

- `nixos-generators` 1.8.0, and the **`qcow-efi`** format exists — the plan is valid as
  written.
- `nixpkgs` resolves via Determinate's FlakeHub `nixpkgs-weekly`, not the NixOS channel.
  Phase 1's flake should pin `nixpkgs` explicitly in its own inputs rather than relying on
  the ambient `extra-nix-path`.

## Open question Phase 1 should settle

The plan says to build the image with `nixos-generators`' `qcow-efi` format. An
alternative worth a moment's thought once the flake exists: NixOS can also produce a
bootable image via `nixos-rebuild build-image` / the `image` modules in recent nixpkgs.
Use whichever evaluates cleanly; note the choice in `learned/phase-1.md`.
