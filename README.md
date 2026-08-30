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
| 2 — Iteration loop from inside the VM | ✅ **complete** |
| 3 — Wayland + Hyprland (software rendering) | ✅ **complete** |
| 4 — Omarchy visual foundations | ✅ **complete** |
| 5 — My software + the agent | ✅ **complete** |
| 6 — GPU acceleration (stretch, allowed to fail) | ⬜ |

## Read these first

| File | What it is |
|---|---|
| **[`PLAN-v1.md`](PLAN-v1.md)** | The plan. Fixed decisions, phase-by-phase steps, acceptance criteria, known risks. |
| **[`learned/phase-0.md`](learned/phase-0.md)** | Measured findings from Phase 0. **Several contradict upstream documentation** — read before touching QEMU or Nix config. |
| **[`learned/phase-1.md`](learned/phase-1.md)** | Measured findings from Phase 1 — why the image is built with nixpkgs' own `image.modules` and not `nixos-generators`, and what the guest needs to boot on this host. |
| **[`learned/phase-2.md`](learned/phase-2.md)** | Measured findings from Phase 2 — the two loops, why the host and the VM are two git repos rather than one 9p share, and which files a rebuild can and cannot see. |
| **[`learned/phase-3.md`](learned/phase-3.md)** | Measured findings from Phase 3 — how to screenshot and type into the VM without a human, and why both of the software-rendering environment variables everyone recommends are wrong here. |
| **[`learned/phase-4.md`](learned/phase-4.md)** | Measured findings from Phase 4 — why GTK 4 draws nothing without `GSK_RENDERER=cairo`, why hyprpaper segfaults on virtio-gpu, and why Nerd Font glyphs have to be written as codepoints. |
| **[`learned/phase-5.md`](learned/phase-5.md)** | Measured findings from Phase 5 — why a launcher cannot see software a rebuild just installed, which Node builds from source, and why every nvim-treesitter guide now configures nothing. |

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
an agent drives it. It keeps the virtio-GPU either way — Hyprland needs a DRM device to
bind, and QEMU renders the screen into memory whether or not anyone is watching. The login
password is `bento`; the host's `~/.ssh/id_ed25519` is already authorized, so SSH needs no
password.

Expect step 2 to take a while the first time. It runs on the builder VM, and the last
stage of it — laying out the partitions and installing systemd-boot — runs a *second*,
nested Linux VM that has no KVM to accelerate it. Everything after Phase 2 happens inside
the bento VM instead, where no builder is involved at all.

If the VM ever comes up at a `Shell>` prompt instead of booting, the EFI variable store has
a stale boot entry — most likely because the emulated hardware changed underneath it.
`./scripts/run-vm.sh --reset-vars` clears it.

## Seeing the screen without looking at it

`run-vm.sh` opens a QMP socket at `artifacts/qmp.sock`, which is enough to photograph the
guest's display and to press keys on its keyboard — under `--headless`, from a script, with
no window on screen:

```bash
./scripts/vm-screenshot.sh                                  # -> artifacts/screen-<stamp>.png
./scripts/vm-screenshot.sh --key meta_l-ret                 # Super+Return, then capture
./scripts/vm-screenshot.sh --type 'hyprctl monitors' --key ret
```

This is how Phase 3's "boots into Hyprland", Phase 4's "the launcher opens on Super+Space"
and Phase 5's "Ghostty, Chromium and Neovim all launch from the launcher" were verified
without a human at the monitor — including typing a password into the lock screen to check
that PAM accepts it. Key names are QEMU's: Super is `meta_l`, Return is `ret`, Space is
`spc`.

Looking at the picture answers *"is something there?"*. For *"is it the right colour?"* —
a different question, and the one a theme change actually turns on — read the pixels back
as numbers and compare them with `home/chime/theme/`:

```bash
./scripts/screen-colors.py artifacts/screen-*.png --hist    # the 12 commonest colours
./scripts/screen-colors.py artifacts/screen-*.png 960,540   # one pixel
```

## The desktop

The VM boots straight into Hyprland — greetd autologins `chime`, no password — and the
session runs on llvmpipe, because this host's QEMU has no OpenGL at all
(`learned/phase-0.md` §2). Expect it to be sluggish; that is Phase 6's problem.

Phase 4 added the Omarchy foundations on top: **waybar** across the top, **walker** on
Super+Space (with **elephant** behind it), **mako** for notifications, **hyprlock** +
**hypridle**, and **swaybg** holding a generated Tokyo Night wallpaper.

Phase 5 put the software on it: **Ghostty** as the terminal, **Chromium** as the browser,
a LazyVim-flavoured **Neovim**, and **Claude Code**.

| Key | Does |
|---|---|
| `Super+Return` | terminal (`ghostty`; `foot` stays installed as the fallback) |
| `Super+B` | browser (`chromium`) |
| `Super+Space` | launcher |
| `Super+L` | lock |
| `Super+W` | close window |
| `Super+F` / `Super+V` | fullscreen / toggle floating |
| `Super+1..9`, `Super+0` | workspaces (with `Shift` to move the window there) |
| `Super+←↑↓→` | move focus (with `Shift` to swap windows) |
| `Super+Shift+S` | screenshot to `~/Pictures` |
| `Super+Shift+Q` | quit Hyprland, back to a text login |

Every colour on that desktop comes from `home/chime/theme/` — a palette, a set of *roles*
that the configs actually read, and the ANSI 16 for terminals. Swapping themes later means
another file exporting the same role names. Both terminals and Neovim read that same
theme; ghostty gets it as a named theme file, and Neovim gets it from `tokyonight.nvim`
upstream, which is where the palette came from in the first place.

The wallpaper is generated rather than downloaded, so the repo carries no image of unknown
provenance:

```bash
python3 scripts/make-wallpaper.py     # -> home/chime/theme/tokyo-night.png, deterministic
```

## The two loops

Changing bento does **not** mean rebuilding the disk image. The image is a seed; the
machine rewrites itself from the flake after that.

### Fast loop — daily, seconds

Edit the config inside the VM and apply it in place. Measured on this host: **6 s** to add
a cached package, **1 s** for a no-op reapply.

```bash
./scripts/run-vm.sh --headless      # if it isn't already up
ssh -p 2222 chime@localhost

cd ~/bento
$EDITOR modules/core.nix            # or ask the agent to
bento rebuild                       # nixos-rebuild switch --flake ~/bento#bento-vm
```

`bento` is part of the OS (`modules/bento-cli.nix`), not a shell alias:

| Command | What it does |
|---|---|
| `bento rebuild [ACTION]` | Build and activate. `ACTION` defaults to `switch`; `boot`, `test`, `dry-activate`, `build` also work. Anything after `--` goes to `nixos-rebuild`. |
| `bento update [INPUT...]` | Refresh `flake.lock`. Applies nothing — follow with `bento rebuild`. |
| `bento gc [--older-than 30d \| --all]` | Delete old generations, sweep the store, rewrite the boot menu. |
| `bento doctor` | What is running, which commit it came from, whether the flake has drifted from it, failed units, disk. Reads only — safe at any moment. |

Rollback is the ordinary NixOS one: pick an older generation in the boot menu, or
`nixos-rebuild switch --rollback`. Note that `bento gc --all` deletes the generations
that make that possible — prefer `--older-than`.

### Clean loop — occasional, ~25 minutes

Rebuild the image on macOS and boot a fresh VM. Needed when the change is one the fast
loop cannot make (bootloader, partitioning) or when the guest has drifted somewhere you'd
rather not reason about.

```bash
./scripts/start-linux-builder.sh
./scripts/build-image.sh            # replaces artifacts/bento.qcow2 — the old guest is gone
./scripts/run-vm.sh --headless
./scripts/vm-sync.sh init           # re-seed ~/bento in the new guest
```

**The clean loop destroys the guest's state**, including its copy of the repo. Get your
commits out first (`./scripts/vm-sync.sh pull`).

### Moving commits between here and the VM

The host repo and the VM's `~/bento` are two real git repositories, and both directions
are driven from the host. Not because the other direction is impossible — the guest can
reach the Mac at `10.0.2.2` — but because that route depends on macOS Remote Login being
enabled and on the guest holding a credential for the host account. The 2222 forward
needs neither.

```bash
./scripts/vm-sync.sh init      # seed ~/bento in the VM, add the `vm` remote here
./scripts/vm-sync.sh push      # this repo  ->  the VM's working tree
./scripts/vm-sync.sh pull      # the VM     ->  this repo  (fast-forward only)
./scripts/vm-sync.sh status    # who is ahead of whom
```

`push` lands in the VM's checked-out tree via `receive.denyCurrentBranch=updateInstead`,
and is refused outright if that tree is dirty. `pull` refuses to merge a divergence.
Nothing is overwritten silently in either direction.

Handy, since the VM's host key changes every time the image is rebuilt:

```
# ~/.ssh/config
Host bento
  HostName localhost
  Port 2222
  User chime
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
```

## Agent-driven OS

This is the part that is not just a dotfiles repo with extra steps. `~/bento` inside the
VM is a real git repository containing the definition of the machine you are logged into,
and Claude Code is installed system-wide. So the loop is:

```bash
ssh -p 2222 chime@localhost
cd ~/bento
claude                      # then: "add ripgrep-all and bind it to Super+G"
                            #       "the bar should show the date as well as the time"
                            #       "why did the last rebuild fail?"
bento rebuild               # the agent can run this itself
```

The agent edits `modules/*.nix` or `home/chime/*.nix`, runs `bento rebuild`, and the
machine becomes the thing it just described. Nothing is installed imperatively; there is
no state to reconcile afterwards, and `nixos-rebuild switch --rollback` undoes any of it.

What makes that workable rather than alarming:

| | |
|---|---|
| **`bento doctor`** | The cheapest possible context. What is running, which commit it was built from, whether the working tree has drifted from it, what has failed. Run it first. |
| **Rollback is free** | Every rebuild is a new generation; the old one is still in the boot menu. `bento gc --all` is the only thing that removes that safety net, which is why the default is `--older-than 30d`. |
| **The tree must be tracked** | A flake sees only what git tracks, and an untracked file that nothing imports yet is invisible *silently* (`learned/phase-2.md` §3). `bento rebuild` runs `git add -N` over untracked files first, and `bento doctor` reports them. |
| **The VM is disposable** | It is a qcow2 on the host. Worst case, `./scripts/vm-sync.sh pull` and rebuild the image. |

Claude Code needs to be logged in once, interactively, with your own credentials — an
agent cannot do that for you. Run `claude` and follow the prompt; the token lands in
`~/.claude` in the guest's home directory, which survives every `bento rebuild` and does
**not** survive the clean loop.

The tools the agent leans on — `ripgrep`, `fd`, `gh`, `jq`, `curl`, `nodejs-slim` — are in
`modules/agent.nix` rather than in anyone's home profile, because they are part of what
this machine *is*.

## Layout

```
bento/
├── flake.nix                     # inputs + nixosConfigurations.bento-vm + bento-image
├── hosts/bento-vm/
│   ├── default.nix               # which modules make up this machine
│   └── hardware.nix              # virtio, EFI/systemd-boot, serial console, disk layout
├── modules/
│   ├── core.nix                  # users, ssh, nix settings, locale — host-agnostic
│   ├── bento-cli.nix             # the `bento` command: rebuild / update / gc / doctor
│   ├── desktop.nix               # Hyprland, greetd autologin, the graphical session
│   ├── fonts.nix                 # CaskaydiaMono Nerd Font + fallbacks
│   └── agent.nix                 # claude-code and the tools it leans on
├── home/chime/
│   ├── default.nix               # home-manager entry point
│   ├── hyprland.nix              # keybindings, and what to switch off with no GPU
│   ├── ghostty.nix               # the terminal
│   ├── foot.nix                  # the fallback terminal, themed the same way
│   ├── chromium.nix              # the browser, and the xdg-open default
│   ├── neovim.nix                # the editor: LazyVim's plugin set, declaratively
│   ├── neovim/init.lua           #   …and its configuration, as actual Lua
│   ├── waybar.nix                # the bar
│   ├── walker.nix                # the launcher + elephant
│   ├── mako.nix                  # notifications
│   ├── wallpaper.nix             # swaybg (hyprpaper crashes here — phase-4 §3)
│   ├── lock.nix                  # hyprlock + hypridle
│   └── theme/                    # colors.nix (palette, roles, ANSI 16) + wallpaper
├── PLAN-v1.md                    # the plan
├── learned/                      # findings log, one file per completed phase
│   ├── phase-0.md
│   ├── phase-1.md
│   ├── phase-2.md
│   ├── phase-3.md
│   ├── phase-4.md
│   └── phase-5.md
└── scripts/
    ├── setup-linux-builder.sh    # one-time root setup of the aarch64-linux builder
    ├── start-linux-builder.sh    # start/check the builder VM (no sudo)
    ├── build-image.sh            # build the qcow2 and stage artifacts/bento.qcow2
    ├── make-wallpaper.py         # regenerate home/chime/theme/tokyo-night.png
    ├── run-vm.sh                 # boot it in QEMU
    ├── vm-screenshot.sh          # photograph the guest's screen / send it keystrokes
    ├── screen-colors.py          # …and read the colours back out of that PNG, as numbers
    └── vm-sync.sh                # move commits between this repo and the VM's ~/bento
```

## Working on this with agents

One phase per agent session. Each agent must read `PLAN-v1.md` **and every
`learned/phase-*.md`** before starting, then write its own `learned/phase-N.md` when
done. The learned files exist because a agent working from upstream documentation alone
will repeat mistakes already paid for — for example, restarting a Nix daemon under a
launchd label that does not exist on this machine, or trusting an acceptance test that
passes without testing anything.
