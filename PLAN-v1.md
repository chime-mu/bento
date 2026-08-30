# PLAN v1 — bento: a NixOS desktop OS, Omarchy-inspired, agent-supported

## Vision

**bento** is a personal desktop OS in the spirit of DHH's Omarchy — an opinionated,
keyboard-driven Hyprland desktop — but built on **NixOS** instead of Arch, with the
package list chosen by *me*, not DHH. The OS is declarative (one flake describes the
whole machine) and agent-supported: **Claude Code is a first-class citizen** installed
from day one, and the OS configuration itself is designed so an agent inside the VM can
read, modify, and apply it (`nixos-rebuild switch --flake`).

v1 runs as a QEMU virtual machine on an Apple Silicon MacBook. Bare-metal comes later.

## Decisions (already made — do not re-litigate)

| Topic | Decision |
|---|---|
| Guest architecture | `aarch64-linux` (Apple Silicon host, QEMU + hvf acceleration) |
| Distro | NixOS unstable channel, flakes + home-manager |
| Build path | Nix installed on macOS builds the qcow2 disk image (via a Linux remote builder); day-to-day iteration happens *inside* the VM with `nixos-rebuild switch` |
| VM runner | Scripted QEMU (`scripts/run-vm.sh`), not UTM |
| Desktop | Wayland + Hyprland, Waybar, Walker launcher, Mako notifications, hyprlock/hypridle — the Omarchy visual foundations |
| Fonts / theme | CaskaydiaMono Nerd Font, Tokyo Night as the first theme (Omarchy's defaults) |
| v1 software | Ghostty (terminal), Chromium (browser), Neovim (LazyVim-style), Claude Code, git + dev basics |
| Names | OS/flake/hostname: `bento` · VM host: `bento-vm` · user: `chime` |
| Graphics strategy | Boot with **software rendering first** (reliable in QEMU on macOS); VirGL/`gl=es` acceleration is a stretch goal (Phase 6) |

Prior art: [try-omarchy](https://github.com/themartiano/try-omarchy) runs an ARM64 Arch
guest with QEMU + Hypervisor.framework + VirGL. We borrow its QEMU approach; the guest
is NixOS instead.

## Repository layout (target)

```
bento/
├── flake.nix                  # inputs: nixpkgs (nixos-unstable), home-manager, nixos-generators
├── flake.lock
├── hosts/
│   └── bento-vm/
│       ├── default.nix        # host config: imports modules, VM-specific bits
│       └── hardware.nix       # virtio, qemu guest profile, filesystems
├── modules/
│   ├── core.nix               # users, ssh, nix settings, allowUnfree, locale
│   ├── desktop.nix            # Hyprland, greetd autologin, XDG portals, pipewire
│   ├── fonts.nix              # CaskaydiaMono Nerd Font + friends
│   └── agent.nix              # Claude Code + everything an agent needs
├── home/
│   └── chime/
│       ├── default.nix        # home-manager entry point
│       ├── hyprland.nix       # keybindings, monitors, autostart (Omarchy-inspired)
│       ├── waybar.nix
│       ├── walker.nix
│       ├── mako.nix
│       ├── ghostty.nix
│       ├── neovim.nix         # LazyVim-style setup
│       └── theme/             # Tokyo Night colors shared across apps
├── scripts/
│   ├── build-image.sh         # builds the qcow2 via nixos-generators
│   └── run-vm.sh              # launches QEMU with the right flags
├── PLAN-v1.md                 # this file
└── README.md
```

---

## Phases

Each phase below is scoped to be handed to one implementation agent (Opus). Every phase
ends with **acceptance criteria** — the agent must verify them (or, where only a human
at the screen can, print exact instructions for me to verify) before the phase is done.

### Phase 0 — macOS host prerequisites

*Mostly manual / interactive; the agent prepares commands and verifies results.*

1. Install Nix on macOS (Determinate Systems installer recommended: multi-user, flakes
   enabled by default).
2. Set up an `aarch64-linux` builder so macOS can build Linux derivations. Two options,
   prefer (a):
   - a) `darwin.linux-builder` from nixpkgs (`nix run nixpkgs#darwin.linux-builder`),
     registered in `/etc/nix/machines` per the
     [nixpkgs manual](https://nixos.org/manual/nixpkgs/unstable/#sec-darwin-builder).
   - b) If I later adopt nix-darwin: `nix.linux-builder.enable = true;`.
3. Install QEMU on the host: `brew install qemu` (or `nix profile install nixpkgs#qemu`).
   Verify `qemu-system-aarch64 --version` ≥ 9.x and locate the EDK2 firmware
   (`edk2-aarch64-code.fd` in QEMU's share dir).
4. `git init` this repo.

**Acceptance:** `nix build nixpkgs#legacyPackages.aarch64-linux.hello` succeeds on the
Mac; `qemu-system-aarch64 --version` prints.

### Phase 1 — Flake skeleton + bootable headless image

Goal: a minimal NixOS aarch64 qcow2 image that boots in QEMU with serial console + SSH.
No desktop yet — this isolates virtualization problems from desktop problems.

1. Write `flake.nix` with inputs `nixpkgs` (nixos-unstable), `home-manager`,
   `nixos-generators`; output `nixosConfigurations.bento-vm` and a
   `packages.aarch64-linux.bento-image` using nixos-generators format **`qcow-efi`**.
2. `modules/core.nix`:
   - user `chime` (wheel, initial password, ssh authorized key optional),
     passwordless sudo for wheel (it's a dev VM),
   - `nix.settings.experimental-features = [ "nix-command" "flakes" ]`,
   - `nixpkgs.config.allowUnfree = true` (needed for `claude-code`),
   - openssh enabled, `git`, `vim`, `htop` in systemPackages,
   - hostname `bento`, sensible locale/timezone (Europe/Copenhagen).
3. `hosts/bento-vm/hardware.nix`: import the qemu-guest profile
   (`modules/profiles/qemu-guest.nix`), systemd-boot on EFI, grow-partition for the
   qcow image, virtio modules.
4. `scripts/build-image.sh`: `nix build .#bento-image` (runs on the Linux builder),
   copies the result to `./artifacts/bento.qcow2` (writable copy, `qemu-img resize` to
   ~60G).
5. `scripts/run-vm.sh` (v1, headless-friendly):
   ```
   qemu-system-aarch64 \
     -machine virt,accel=hvf -cpu host -smp 4 -m 8G \
     -drive if=pflash,format=raw,readonly=on,file=<edk2-aarch64-code.fd> \
     -drive if=virtio,format=qcow2,file=artifacts/bento.qcow2 \
     -device virtio-gpu-pci -display cocoa \
     -device qemu-xhci -device usb-kbd -device usb-tablet \
     -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
     -serial mon:stdio
   ```

**Acceptance:** VM boots to a login prompt; `ssh -p 2222 chime@localhost` works;
`nixos-version` inside prints an unstable version; the flake evaluates with
`nix flake check`.

### Phase 2 — Iteration loop from inside the VM

Goal: the agent-friendly workflow — change the OS without rebuilding the image.

1. Inside the VM, clone/copy the bento repo to `~/bento` (initially via
   `scp -P 2222`; later git remote). The qcow2 image is a *base*; from now on changes
   apply via `sudo nixos-rebuild switch --flake ~/bento#bento-vm`.
2. Add a `bento` shell alias/script inside the VM: `bento rebuild`, `bento update`
   (flake update), `bento gc`.
3. Document both loops in README:
   - **Fast loop (daily):** edit in VM → `bento rebuild` (seconds–minutes).
   - **Clean loop (occasional):** rebuild image on macOS → fresh VM.

**Acceptance:** editing `modules/core.nix` inside the VM (e.g. add a package) and
running `bento rebuild` makes the package available without re-imaging.

### Phase 3 — Wayland + Hyprland desktop (software rendering)

Goal: log in and land in Hyprland inside the QEMU window.

1. `modules/desktop.nix`:
   - `programs.hyprland.enable = true;`
   - `greetd` with autologin for `chime` into Hyprland (dev VM — no password wall),
   - pipewire, xdg-desktop-portal-hyprland, polkit.
2. Software-rendering environment for the VM (Hyprland has no real GPU under
   virtio-gpu on macOS): set the environment variables Hyprland/aquamarine need to run
   with llvmpipe/software rendering and no hardware cursors (verify current variable
   names against Hyprland ≥ current-release docs — they have changed across versions;
   e.g. historically `WLR_NO_HARDWARE_CURSORS=1`, `LIBGL_ALWAYS_SOFTWARE=1`). Gate
   these behind the `bento-vm` host so a future bare-metal host doesn't inherit them.
3. Minimal `home/chime/hyprland.nix`: Super-based keybindings following Omarchy's
   scheme (Super+Return terminal, Super+Space launcher, Super+W close, Super+1..9
   workspaces), foot or ghostty as terminal once Phase 4 lands (use foot as temporary
   fallback if ghostty misbehaves under software rendering).

**Acceptance:** VM boots straight into Hyprland; a terminal opens with Super+Return;
`echo $XDG_SESSION_TYPE` prints `wayland`. Expect it to be sluggish — that's fine.

### Phase 4 — Omarchy visual foundations

Goal: it should *look* like Omarchy's family: same fonts, same bar/launcher/notification
trio, Tokyo Night theme.

1. `modules/fonts.nix`: `nerd-fonts.caskaydia-mono` (check the nixpkgs `nerd-fonts.*`
   namespace for the current attribute), plus Liberation/Noto fallbacks, fontconfig
   defaults to CaskaydiaMono for monospace.
2. home-manager modules:
   - **Waybar** — top bar, workspaces / clock / tray, Tokyo Night colors.
   - **Walker** — launcher bound to Super+Space (package `walker` in nixpkgs; if it's
     broken on aarch64, fall back to `fuzzel` and note it).
   - **Mako** — notifications, themed.
   - **hyprlock + hypridle** — lock/idle (idle timers long in a VM).
   - **hyprpaper** + one Tokyo Night wallpaper committed under `home/chime/theme/`.
3. `home/chime/theme/`: a single `colors.nix` exporting the Tokyo Night palette that
   waybar/mako/ghostty/hyprland configs all import — this becomes the seam for a future
   Omarchy-style theme switcher (out of scope for v1).

**Acceptance:** screenshot of the desktop shows themed bar, launcher opens with
Super+Space, `notify-send test` shows a themed notification.

### Phase 5 — My software + the agent

Goal: the v1 app list, with Claude Code working.

1. **Ghostty** (`ghostty` in nixpkgs) as default terminal, CaskaydiaMono, Tokyo Night,
   bound to Super+Return. Keep foot installed as fallback.
2. **Chromium** as default browser (Super+B, and `xdg-open` default). If the aarch64
   binary cache is missing (avoid a source build!), substitute Firefox and flag it in
   the phase report.
3. **Neovim** LazyVim-style via home-manager (`programs.neovim` + LazyVim config files;
   don't over-engineer with nixvim in v1).
4. **`modules/agent.nix` — the point of the OS:**
   - `claude-code` from nixpkgs (unfree — already allowed), plus `nodejs`, `ripgrep`,
     `fd`, `jq`, `gh`, `curl` — the tools Claude Code leans on,
   - the `~/bento` clone from Phase 2 is the agent's workspace: document (README
     section "Agent-driven OS") that the intended workflow is
     `cd ~/bento && claude` → ask for an OS change → agent edits the flake →
     `bento rebuild`,
   - `bento doctor` script: prints flake status, last rebuild, disk space — cheap
     context for the agent.

**Acceptance:** inside the VM, `claude --version` works; a smoke test of
`cd ~/bento && claude` (interactive; I verify login myself — API auth needs my
credentials); Ghostty, Chromium, and Neovim all launch from the Walker launcher.

### Phase 6 (stretch) — GPU acceleration

Only after Phases 1–5 are stable. Software rendering will be the painful part of v1;
this phase tries to fix it.

1. Try host QEMU with VirGL: `-device virtio-gpu-gl-pci -display cocoa,gl=es`.
   Homebrew's QEMU may or may not ship virgl/ANGLE support — check
   `qemu-system-aarch64 -device help | grep gl` and the display backends; if absent,
   try a virgl-enabled build (e.g. the approach in
   [knazarov/homebrew-qemu-virgl](https://github.com/knazarov/homebrew-qemu-virgl) or a
   nix-built QEMU with virglrenderer + ANGLE).
2. Guest side: mesa with virgl driver (default in NixOS), drop the software-rendering
   env vars for a test session.
3. If it works: `run-vm.sh --gl` flag switches modes. If not: document findings, stay
   on software rendering, revisit later (this is exactly the part try-omarchy solved
   with a custom QEMU build — their approach is the reference).

**Acceptance:** `glxinfo -B` (or `eglinfo`) in the guest reports virgl instead of
llvmpipe, and Hyprland animations are visibly smooth. *This phase is allowed to fail.*

---

## How to run this plan with agents

- One phase = one agent session. Prompt shape: *"Implement Phase N of PLAN-v1.md in
  this repo. Read the plan first. Decisions in the table are fixed. Verify the
  acceptance criteria; anything you cannot verify yourself (needs the VM screen or my
  credentials), list as manual steps for me at the end. If a named package/option
  doesn't exist in current nixpkgs, find the current equivalent and note the
  substitution in your report."*
- Phases 0–1 involve the macOS host (installs, permission prompts) — run those
  interactively. Phases 3–5 are mostly flake edits and can run with less supervision;
  they can even run *inside the VM* using the Phase 2 loop.
- Keep commits per phase: `phase-1: bootable headless image`, etc.

## Known risks

1. **Graphics on macOS-hosted QEMU** — the big one. Mitigated by software-rendering
   first, VirGL as a separate failable phase.
2. **aarch64 binary cache gaps** (Chromium, Ghostty) — never build these from source in
   the VM; substitute and report instead.
3. **Hyprland-in-VM env vars churn** — variable names for software rendering / cursors
   have changed across Hyprland versions; the implementing agent must check current
   docs rather than trust the examples here.
4. **Linux builder on macOS** — first-time setup can be fiddly (trust settings,
   `/etc/nix/machines`). Phase 0 is interactive for a reason.
5. **Walker on aarch64** — fallback to fuzzel is pre-authorized.
