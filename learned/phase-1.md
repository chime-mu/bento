# What Phase 1 taught us

**Date:** 2026-08-30 · **Host:** Apple Silicon MacBook (M4, 10 cores, 32 GiB), macOS 26.5.2
**Outcome:** ✅ Phase 1 complete — a NixOS `aarch64-linux` qcow2 boots in QEMU, takes SSH,
and reports an unstable release.

Findings log for Phase 1: the flake skeleton and the first bootable headless image.
Everything here was measured on this machine. Where it contradicts `PLAN-v1.md` or
upstream documentation, that is called out.

## Acceptance — all four criteria verified

| Criterion | Result |
|---|---|
| VM boots to a login prompt | ✅ `bento login:` on `ttyAMA0` |
| `ssh -p 2222 chime@localhost` | ✅ key-based, no password |
| `nixos-version` is unstable | ✅ `26.11.20260828.83199d0 (Zokor)` |
| `nix flake check` | ✅ exit 0, all outputs green |

Also confirmed inside the guest: `aarch64` / Linux 6.18.47, hostname `bento`, passwordless
sudo, `Europe/Copenhagen` (CEST), `git`/`vim`/`htop` present, home-manager applied (git
identity set, `git` resolving via `/etc/profiles/per-user/chime`), and the root filesystem
grown from the 8 GiB build size to **59 G of the 60 G disk** — so `growPartition` +
`autoResize` work as intended.

The bootloader landed in both places, which is the thing that makes a blank NVRAM boot:

```
/boot/EFI/BOOT/BOOTAA64.EFI          ← removable-media fallback, the one firmware finds
/boot/EFI/systemd/systemd-bootaa64.efi
```

---

## 1. `nixos-generators` is deprecated — we build with nixpkgs' own image modules

`PLAN-v1.md` Phase 1 step 1 says to use `nixos-generators`' `qcow-efi` format, and
Phase 0 verified that format exists. It still does, and it still works. But it now
prints, on every evaluation:

```
evaluation warning: nixos-generators is deprecated, since it has been upstreamed
into nixpkgs as of NixOS 25.05.
```

The upstream replacement is `nixos/modules/image/images.nix`, which is already in
nixpkgs' default module list. It declares `image.modules.<variant>` and exposes
`config.system.build.images.<variant>`. The variant matching `qcow-efi` is
**`qemu-efi`** (`nixos/modules/virtualisation/disk-image.nix`).

So `packages.aarch64-linux.bento-image` is simply:

```nix
self.nixosConfigurations.bento-vm.config.system.build.images.qemu-efi
```

**This is a deliberate substitution from the plan.** Three reasons, in order of weight:

1. **It resolves a contradiction inside the plan itself.** Step 1 asks for
   nixos-generators' `qcow-efi`, step 3 asks for **systemd-boot**. They are incompatible:
   `qcow-efi.nix` hardcodes `boot.loader.grub.efiSupport = true` with
   `efiInstallAsRemovable`. nixpkgs' `qemu-efi` uses
   `boot.loader.systemd-boot.enable = lib.mkDefault cfg.efiSupport`, so it satisfies both
   steps at once.
2. **`extendModules` instead of a parallel evaluation.** `images.nix` layers the format
   module *on top of* the real configuration. The image and
   `nixosConfigurations.bento-vm` are therefore the same machine by construction. With
   nixos-generators the image is a separate `nixosSystem` call that merely happens to be
   given the same module list.
3. One less flake input, and no deprecation warning on every build.

Nothing was lost: `image.format` still defaults to `qcow2`, and the partition table is
still `efi`. Both paths call the same `nixos/lib/make-disk-image.nix` underneath.

## 2. The image module and `nixos-rebuild` disagree about who owns the disk layout

This is the one structural trap in Phase 1, and it will bite Phase 2 if it is undone.

`disk-image.nix` sets `fileSystems."/"`, `fileSystems."/boot"` and `boot.growPartition`
with **plain** definitions. That is fine while building the image. But Phase 2's whole
premise is running `nixos-rebuild switch --flake ~/bento#bento-vm` *inside* the VM, and
that evaluates `nixosConfigurations.bento-vm` **without** the image module. On its own it
has no root filesystem and fails:

```
error: The ‘fileSystems’ option does not specify your root file system.
```

So `hosts/bento-vm/hardware.nix` must state the disk layout too — and every option the
image module also sets is wrapped in `lib.mkDefault`, so the image module's plain
definition wins during the image build and ours applies everywhere else. The two agree
anyway; `mkDefault` just keeps the module system from having to arbitrate.

> **Do not "clean this up" by deleting the fileSystems from `hardware.nix`.** The image
> will still build, and the VM will still boot — and then the first in-VM rebuild fails.

(Worth knowing for future merges: NixOS option types like `bool`, `str` and `path` merge
with `mergeEqualOption`, so two *identical* plain definitions do not actually conflict.
Only differing ones do. `mkDefault` is still the honest way to express "the format module
outranks me here".)

## 3. Serial console on `virt` is `ttyAMA0`, and nothing sets it for us

nixos-generators' `qcow-efi` had an aarch64-aware `boot.consoles` default. nixpkgs'
`qemu-efi` sets **no** kernel console parameters at all. Since `run-vm.sh` relies on
`-serial mon:stdio` to drive the VM headlessly, `hardware.nix` sets them itself:

```nix
boot.kernelParams = [ "console=tty0" "console=ttyAMA0,115200" ];
```

The order matters: the **last** `console=` becomes `/dev/console`, so the serial port gets
the boot messages and the getty, while `tty0` keeps the QEMU graphical window alive for
Phase 3. `ttyS0` — which most x86 examples use, and which `qcow-efi` also passes — does
not exist on the `virt` machine.

## 4. systemd-boot has to install without touching EFI variables

Phase 0 established that Homebrew ships no `edk2-aarch64-vars.fd`, so `run-vm.sh`
fabricates 64 MiB of zeros as the variable store. Every boot therefore starts with an
**empty NVRAM** — no boot entries for firmware to follow.

The configuration that makes this work:

```nix
boot.loader.systemd-boot.enable = true;
boot.loader.efi.canTouchEfiVariables = false;
```

With `canTouchEfiVariables = false`, `bootctl install` runs `--no-variables` and leaves a
copy of the loader at the removable-media fallback path `/EFI/BOOT/BOOTAA64.EFI`, which
is exactly what firmware falls back to when NVRAM is empty. (`make-disk-image.nix`
supports this explicitly — it even symlinks `/dev/block/254:1` inside its build VM so
`bootctl` can find the ESP without udev.)

## 5. The image build needs a nested VM, and Nix refuses to schedule it

This was the one real wall in Phase 1, and it cost the most time. It is worth
understanding properly, because Phase 0's builder cannot be fixed into supporting it.

`make-disk-image.nix` lays out the partitions and installs the bootloader inside
`pkgs.vmTools.runInLinuxVM`. So the chain on this host is:

```
macOS  →  darwin.linux-builder (QEMU + hvf)  →  make-disk-image's VM (QEMU, no KVM)
```

The middle VM has **no `/dev/kvm`** — hvf exposes no nested virtualisation to its guest —
which was measured directly:

```
$ ssh -p 31022 builder@localhost 'ls -la /dev/kvm'
ls: cannot access '/dev/kvm': No such file or directory
```

And `runInLinuxVM` declares, at `pkgs/build-support/vm/default.nix:412`:

```nix
requiredSystemFeatures = [ "kvm" ];
```

unconditionally. So Nix will not even *schedule* the build:

```
Failed to find a machine for remote build!
required (system, features): (aarch64-linux, [kvm])
1 available machines:
([aarch64-linux], 4, [], [])
```

**The gate is about speed, not capability.** `nixos/lib/qemu-common.nix` builds the inner
QEMU command with

```nix
accel = accelName: if forceAccel then accelName else "${accelName}:tcg";
```

so it is `accel=kvm:tcg` — KVM if present, otherwise emulation. Nothing actually *needs*
KVM; the feature flag only expresses a preference. Dropping the requirement is therefore
honest, not a workaround:

```nix
nixpkgs.lib.overrideDerivation base (_: { requiredSystemFeatures = [ ]; })
```

Note `overrideDerivation`, **not** `overrideAttrs`: `runInLinuxVM` returns a bare
`derivation`, so `overrideAttrs` is missing and you get
`error: attribute 'overrideAttrs' missing`.

Two alternatives were considered and rejected:

- **Advertise `kvm` on the builder anyway** (add it to the `builders` line's feature
  field and to the guest's `nix.settings.system-features`). It would work — `chime` is in
  `extra-trusted-users`, so `--builders` can be overridden from the CLI without sudo — but
  it puts a false claim in two config files to achieve exactly what the one-line override
  achieves honestly.
- **`systemd-repart` images** (`nixos/modules/image/repart.nix`), which need no VM at all.
  Genuinely attractive, and the right answer if the emulated build ever becomes
  intolerable — but it means hand-building the ESP contents and loader entries instead of
  letting `bootctl` do it, which puts Phase 2's `nixos-rebuild switch` on unproven ground.

This is a one-time cost per image, and it is exactly why Phase 2 exists: inside the bento
VM, `nixos-rebuild switch` is a native `aarch64-linux` build — no builder, no nesting, no
image to lay out.

## 6. nixpkgs cannot start a NixOS VM on this Mac at all — GICv2 vs HVF

Raising the builder's resources (below) exposed a second, unrelated bug. The builder VM
would not start:

```
qemu-system-aarch64: HVF does not support GICv2 emulation
```

`nixos/lib/qemu-common.nix` hardcodes the machine type for an aarch64-darwin host as

```
qemu-system-aarch64 -machine virt,gic-version=2,accel=hvf:tcg -cpu max
```

and HVF cannot emulate a GICv2 interrupt controller. `accel=hvf:tcg` does not save it —
the failure happens during machine init, before any accelerator fallback. **This affects
any NixOS VM launched from nixpkgs on Apple Silicon at this revision, at any core count.**
It went unnoticed in Phase 0 only because `nix run nixpkgs#darwin.linux-builder` resolved
through Determinate's FlakeHub `nixpkgs-weekly` (see phase-0 §4.3), a different revision.

Measured directly against qemu 11.1.1:

| Command | Result |
|---|---|
| `-machine virt,gic-version=2,accel=hvf` | `HVF does not support GICv2 emulation` |
| `-machine virt,gic-version=2,accel=hvf -machine gic-version=3` | initialises fine |
| `-machine virt,gic-version=2,accel=hvf -machine gic-version=max` | initialises fine |

The generated `run-nixos-vm` script appends `$QEMU_OPTS` *after* its own flags, and QEMU
merges repeated `-machine` options with last-one-wins. So `start-linux-builder.sh` fixes
it from outside, with no patching of nixpkgs:

```bash
export QEMU_OPTS="-machine gic-version=max ${QEMU_OPTS:-}"
```

`scripts/run-vm.sh` is unaffected — it passes `-machine virt,accel=hvf` and lets QEMU pick
its own default GIC.

## 7. The stock builder is far too small for an emulated build

`darwin.linux-builder` gives the guest **1 core and 3 GiB** (`virtualisation.cores = 1`,
`memorySize = 3072`, both plain definitions in `nixos/modules/profiles/nix-builder.nix`,
so overriding them needs `lib.mkForce`). This host has 10 cores and 32 GiB.

That default is merely slow for ordinary builds, but the image build is an *emulated*
inner VM, which is precisely the workload that wants cores and memory. So the flake
defines its own builder:

```nix
packages.aarch64-darwin.linux-builder =
  nixpkgs.legacyPackages.aarch64-darwin.darwin.linux-builder.override {
    modules = [ ({ lib, ... }: {
      virtualisation.cores = lib.mkForce 8;
      virtualisation.memorySize = lib.mkForce 12288;
    }) ];
  };
```

and `start-linux-builder.sh` runs `nix run "${REPO_ROOT}#linux-builder"` instead of
`nixpkgs#darwin.linux-builder`. Same port, same (publicly known) host key, so the
`builders` line and ssh config Phase 0 installed under `/etc` keep working untouched —
**no sudo was needed for any of this.**

`virtualisation.diskSize` is deliberately *not* overridden: changing it orphans
`~/.local/state/bento/builder-disk.qcow2` and forces the builder to refetch its entire
store.

## 8. Smaller things that cost time

| Gotcha | Detail |
|---|---|
| **`nix` is not on a non-interactive shell's PATH** | Every `Bash`-tool invocation starts a fresh non-login shell where `nix: command not found`. Source `/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh` first — both new scripts do this themselves. |
| **Flakes ignore untracked files** | `nix flake lock` failed with *"Path 'flake.nix' … is not tracked by Git"*. New files need at least `git add -N` before any flake command sees them. |
| **`programs.git.userName` was renamed** | home-manager now wants `programs.git.settings.user.name` / `.email`. The old names still work but warn on every evaluation. |
| **Custom `i18n.supportedLocales` forces a `glibc-locales` source build** | Naming `en_DK`/`da_DK` puts the locale set off the cached path, so glibc-locales compiles from source on the builder. One-time, but it dominates the first image build. `[ "all" ]` is prebuilt if that ever matters more than image size. |
| **`nix build .#bento-image` resolves against the host system** | On macOS that means `packages.aarch64-darwin.bento-image`, which does not exist. The attribute has to be spelled `.#packages.aarch64-linux.bento-image`. |
| **The image module leaks into the system label** | `disk-image.nix` sets `system.nixos.tags = [ "qcow2" "efi" ]`, so the freshly imaged guest greets you as `NixOS efi-qcow2-26.11…`. Cosmetic, and it disappears at the first in-VM `nixos-rebuild switch`, since the tags come from the image module. |

## 9. Settled for later phases — do not re-litigate

- The image builder is nixpkgs' `system.build.images.qemu-efi`, not nixos-generators.
  If a future phase needs a different output format, add a variant to `image.modules`
  rather than reintroducing the flake input.
- `hardware.nix` owns the disk layout and must keep doing so, for the reason in §2.
- The guest boots on systemd-boot via the removable-media fallback. Do not enable
  `canTouchEfiVariables` — there is no persistent NVRAM to write to.
- The builder will never have `/dev/kvm`. Do not try to "fix" the KVM requirement by
  chasing nested virtualisation — keep the `requiredSystemFeatures` override (§5).
  (Apple's Virtualization.framework *does* support nested virt on M3 and later, and this
  host is an M4, so `darwin.linux-builder-vz` is a theoretical future avenue. It needs
  Rosetta installed, which needs sudo, and it was not tested. Not worth it while the
  image build is a once-per-phase cost.)
- Keep `export QEMU_OPTS="-machine gic-version=max …"` in `start-linux-builder.sh` (§6)
  until nixpkgs stops hardcoding `gic-version=2` for aarch64-darwin hosts. Without it the
  builder does not start at all.
