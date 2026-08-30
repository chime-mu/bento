# bento

A personal desktop OS in the spirit of DHH's [Omarchy](https://omarchy.org) — an
opinionated, keyboard-driven Hyprland desktop — but built on **NixOS** instead of Arch,
with the package list chosen by me rather than inherited.

Two things make it different from "another dotfiles repo":

- **It is declarative.** One flake describes the whole machine.
- **It is agent-supported.** Claude Code is a first-class citizen installed from day one,
  and the OS configuration is deliberately shaped so an agent inside the VM can read,
  modify, and apply it (`nixos-rebuild switch --flake ~/bento#bento-vm`).

v1 runs as a QEMU virtual machine on an Apple Silicon MacBook. Bare metal comes later.

---

## Status

| Phase | State |
|---|---|
| 0 — macOS host prerequisites | ✅ **complete** |
| 1 — Flake skeleton + bootable headless image | ✅ **complete** |
| 2 — Iteration loop from inside the VM | ⬜ |
| 3 — Wayland + Hyprland (software rendering) | ⬜ |
| 4 — Omarchy visual foundations | ⬜ |
| 5 — My software + the agent | ⬜ |
| 6 — GPU acceleration (stretch, allowed to fail) | ⬜ |

## Read these first

| File | What it is |
|---|---|
| **[`PLAN-v1.md`](PLAN-v1.md)** | The plan. Fixed decisions, phase-by-phase steps, acceptance criteria, known risks. |
| **[`learned/phase-0.md`](learned/phase-0.md)** | Measured findings from Phase 0. **Several contradict upstream documentation** — read before touching QEMU or Nix config. |
| **[`learned/phase-1.md`](learned/phase-1.md)** | Measured findings from Phase 1 — why the image is built with nixpkgs' own `image.modules` and not `nixos-generators`, and what the guest needs to boot on this host. |

## Host setup

Phase 0 is already done on this machine. What exists:

- QEMU 11.1.1 (Homebrew) with `hvf` and the hypervisor entitlement
- Determinate Nix 3.22.2 (Nix 2.35.2)
- `darwin.linux-builder` configured, so the Mac can build `aarch64-linux` derivations

The builder is a **VM that must be running** for any macOS-side Linux build. It does not
survive a reboot or a closed terminal:

```bash
./scripts/start-linux-builder.sh --check   # is it up?
./scripts/start-linux-builder.sh           # start it (no sudo needed)
```

To verify the toolchain end-to-end — note this deliberately forces an *unsubstitutable*
build, because a cached package would pass even with no builder at all:

```bash
nix build --impure --no-link --print-out-paths --expr \
  'with import <nixpkgs> { system = "aarch64-linux"; };
   runCommand "probe-'"$(date +%s)"'" {} "uname -m > $out; uname -s >> $out"'
```

Should print a store path whose contents are `aarch64` / `Linux`.

Re-running host setup from scratch (idempotent, needs sudo once):

```bash
sudo ./scripts/setup-linux-builder.sh
```

## Build and boot the VM

```bash
./scripts/start-linux-builder.sh   # 1. the builder VM (needed only to build the image)
./scripts/build-image.sh           # 2. build the qcow2, stage a 60 G writable copy
./scripts/run-vm.sh                # 3. boot it — Cocoa window + serial console
ssh -p 2222 chime@localhost        # 4. log in
```

`run-vm.sh --headless` drops the window and leaves only the serial console, which is how
an agent drives it. The login password is `bento`; the host's `~/.ssh/id_ed25519` is
already authorized, so SSH needs no password.

Expect step 2 to take a while the first time. It runs on the builder VM, and the last
stage of it — laying out the partitions and installing systemd-boot — runs a *second*,
nested Linux VM that has no KVM to accelerate it. Everything after Phase 2 happens inside
the bento VM instead, where no builder is involved at all.

## Layout

```
bento/
├── flake.nix                     # inputs + nixosConfigurations.bento-vm + bento-image
├── hosts/bento-vm/
│   ├── default.nix               # which modules make up this machine
│   └── hardware.nix              # virtio, EFI/systemd-boot, serial console, disk layout
├── modules/
│   └── core.nix                  # users, ssh, nix settings, locale — host-agnostic
├── home/chime/                   # home-manager entry point (near-empty until Phase 3)
├── PLAN-v1.md                    # the plan
├── learned/                      # findings log, one file per completed phase
│   ├── phase-0.md
│   └── phase-1.md
└── scripts/
    ├── setup-linux-builder.sh    # one-time root setup of the aarch64-linux builder
    ├── start-linux-builder.sh    # start/check the builder VM (no sudo)
    ├── build-image.sh            # build the qcow2 and stage artifacts/bento.qcow2
    └── run-vm.sh                 # boot it in QEMU
```

## Working on this with agents

One phase per agent session. Each agent must read `PLAN-v1.md` **and every
`learned/phase-*.md`** before starting, then write its own `learned/phase-N.md` when
done. The learned files exist because a agent working from upstream documentation alone
will repeat mistakes already paid for — for example, restarting a Nix daemon under a
launchd label that does not exist on this machine, or trusting an acceptance test that
passes without testing anything.
