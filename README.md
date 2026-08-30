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
| 1 — Flake skeleton + bootable headless image | ⬜ next |
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

## Layout

```
bento/
├── PLAN-v1.md                    # the plan
├── learned/
│   └── phase-0.md                # findings log, one per completed phase
├── scripts/
│   ├── setup-linux-builder.sh    # one-time root setup of the aarch64-linux builder
│   └── start-linux-builder.sh    # start/check the builder VM (no sudo)
└── …                             # flake.nix, hosts/, modules/, home/ arrive in Phase 1
```

## Working on this with agents

One phase per agent session. Each agent must read `PLAN-v1.md` **and every
`learned/phase-*.md`** before starting, then write its own `learned/phase-N.md` when
done. The learned files exist because a agent working from upstream documentation alone
will repeat mistakes already paid for — for example, restarting a Nix daemon under a
launchd label that does not exist on this machine, or trusting an acceptance test that
passes without testing anything.
