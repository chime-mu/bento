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
| Build path | Nix installed on macOS builds the qcow2 disk image (via Determinate Nix's native Linux builder, or `darwin.linux-builder` as fallback); day-to-day iteration happens *inside* the VM with `nixos-rebuild switch` |
| VM runner | Scripted QEMU (`scripts/run-vm.sh`), not UTM |
| Desktop | Wayland + Hyprland, Waybar, Walker launcher, Mako notifications, hyprlock/hypridle — the Omarchy visual foundations |
| Fonts / theme | CaskaydiaMono Nerd Font, Tokyo Night as the first theme (Omarchy's defaults) |
| v1 software | Ghostty (terminal), Chromium (browser), Neovim (LazyVim-style), Claude Code, git + dev basics |
| Names | OS/flake/hostname: `bento` · VM host: `bento-vm` · user: `chime` |
| Graphics strategy | **Software rendering** — confirmed in Phase 0 as the *only* option: the host's QEMU 11.1.1 has no OpenGL/VirGL support compiled in. Acceleration requires replacing host QEMU (Phase 6, stretch) |

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

### Phase 0 — macOS host prerequisites — ⚙️ IN PROGRESS (2026-08-30)

*Mostly manual / interactive; the agent prepares commands and verifies results.*

**Host facts (measured, not assumed):**

| Item | Value |
|---|---|
| Host | Apple Silicon (`arm64`), macOS 26.5.2 (build 25F84) |
| Homebrew | 6.0.17 ✅ present |
| QEMU | 11.1.1 ✅ installed via `brew install qemu` |
| Accelerators | `hvf`, `tcg` ✅ — hvf available as planned |
| EFI firmware | `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` (64 MiB) |
| Nix | ✅ **Determinate Nix 3.22.2** (Nix 2.35.2), installed via `nix-installer --determinate` |
| Linux builder | ❌ **NOT working** — `platform mismatch: Required system 'aarch64-linux', Current system 'aarch64-darwin'` |
| git repo | ✅ initialized, `main`, first commit `9dfd1fe` |

**⚠️ Acceptance-criterion correction.** The original criterion —
`nix build nixpkgs#legacyPackages.aarch64-linux.hello` — is **worthless as a test**: it
passes on a Mac with no Linux builder at all, because `hello` is simply *substituted*
from cache.nixos.org. Never use it. The valid probe forces an unsubstitutable build:

```
nix build --impure --no-link --expr \
  'with import <nixpkgs> { system = "aarch64-linux"; };
   runCommand "probe-'"$(date +%s)"'" {} "uname -m > $out"'
```

**Linux-builder state (measured 2026-08-30):**
- `determinate-nixd version` lists only `lazy-trees` — **`native-linux-builder` is not
  enabled**.
- But the machinery is all present: `/usr/local/bin/determinate-nixd` is signed by
  Determinate Systems (Team `X3JQ4VPJZ6`) and **carries the
  `com.apple.security.virtualization` entitlement**, and a hidden
  `determinate-nixd builder <BUILDER_JSON>` subcommand exists with `--memory-size`,
  `--cpu-count`, `--kernel`, `--initrd` options.
- `nix config show` knows `external-builders` (currently `[]`).
- FlakeHub auth: **logged-out**. `trusted-users = root` only, so the setting cannot be
  overridden from the CLI by `chime` — it must go in a root-owned config file.
- Determinate manages `/etc/nix/nix.conf` (it is overwritten on upgrade); user config
  belongs in **`/etc/nix/nix.custom.conf`**, which `nix.conf` pulls in via
  `!include nix.custom.conf`.
- Daemon label for restarts: **`systems.determinate.nix-daemon`**.

**Option (a) — Determinate native Linux builder: ❌ RULED OUT.** Configuring
`external-builders` correctly is not enough; the feature is **licence-gated server-side**.
The build reaches Determinate's service and is refused:

```
Error: failed to set up Native Linux Builder
Caused by: HTTP status code 400 Bad Request, reply:
  The Native Linux Builder is not currently available.
  Contact support@determinate.systems for more information.
```

Do not retry this without an arrangement with Determinate Systems. **The
`external-builders` setting must be actively removed**, because while present it
hijacks Linux builds and fails instead of falling through to a remote builder.

**Option (b) — `darwin.linux-builder`: ✅ CHOSEN.** Free, no account, documented in
[nixpkgs `doc/packages/darwin-builder.section.md`](https://github.com/NixOS/nixpkgs/blob/master/doc/packages/darwin-builder.section.md).
Runs a small NixOS VM on host port **31022**, reached over SSH as `builder@linux-builder`.

*Pre-flight (verified 2026-08-30):* `nix build --dry-run nixpkgs#darwin.linux-builder`
reports **664 paths fetched, 0 built** (715 MiB download / 2.9 GiB unpacked) — so there
is **no chicken-and-egg problem**; the builder itself needs no Linux builder.

*Two deviations from the stock nixpkgs instructions — both mandatory here:*
1. Settings go in **`/etc/nix/nix.custom.conf`**, not `nix.conf` (Determinate rewrites
   `nix.conf` on upgrade).
2. The daemon restart is `sudo launchctl kickstart -k system/`**`systems.determinate.nix-daemon`**
   — the documented `org.nixos.nix-daemon` label **does not exist** on Determinate Nix,
   so the stock command silently does nothing.

All of this is encoded in **`scripts/setup-linux-builder.sh`** (idempotent; backs up
`nix.custom.conf`; strips the dead `external-builders` config). Run it once:

```
sudo ./scripts/setup-linux-builder.sh
nix run nixpkgs#darwin.linux-builder    # separate terminal, LEAVE RUNNING
```

The builder VM must be running for any macOS-side Linux build (i.e. Phase 1's image
build). Stop it with `shutdown now` at its prompt. Note this is only needed to produce
the *initial* image — per Phase 2, all later iteration happens inside the bento VM
itself, which is natively `aarch64-linux` and needs no builder.

*Alternative if the QEMU builder proves slow:* `darwin.linux-builder-vz` is a drop-in
replacement using Apple's Virtualization.framework (same port, same host key, same
config) — but it requires Rosetta installed, so it is not the default choice here.

**Note — there is no `edk2-aarch64-vars.fd`** shipped by Homebrew (only `edk2-arm-vars.fd`).
Phase 1 must create a writable 64 MiB vars pflash itself, e.g.
`dd if=/dev/zero of=artifacts/edk2-aarch64-vars.fd bs=1m count=64`, and pass it as the
second `if=pflash` drive. Both pflash drives must be 64 MiB.

**Step 1 — Install Nix (⚠️ requires me to run it; sudo needs a password):**

```
curl -fsSL https://install.determinate.systems/nix | sh -s -- install --determinate --no-confirm
```

Installer verified as v3.22.2, flags confirmed against `nix-installer install --help`.
`--determinate` is chosen deliberately — see Step 2.

**Step 2 — `aarch64-linux` builder. Try (a) first, fall back to (b):**

- a) **Determinate Nix native Linux builder** (preferred): builds Linux derivations
  through macOS's Virtualization.framework — no VM to manage, no `/etc/nix/machines`.
  Introduced in Determinate Nix 3.8.4 as a gated preview; we are installing 3.22.2, so
  it may now be on by default. **Check with `determinate-nixd version`** — look for
  `The feature native-linux-builder is enabled`. If it is not enabled, it may need, in
  `/etc/nix/nix.custom.conf`:
  ```
  extra-experimental-features = external-builders
  external-builders = [{"systems":["aarch64-linux","x86_64-linux"],"program":"/usr/local/bin/determinate-nixd","args":["builder"]}]
  ```
  (Verify the current config path and syntax against
  <https://docs.determinate.systems/determinate-nix/linux-builder/> — this moved from
  `nix.conf` to `nix.custom.conf` under Determinate Nix.)
- b) **`darwin.linux-builder`** from nixpkgs — the conventional fallback: a NixOS VM
  registered in `/etc/nix/machines`, per the
  [nixpkgs manual](https://nixos.org/manual/nixpkgs/unstable/#sec-darwin-builder).
  Requires adding `chime` to `trusted-users`.

**Step 3 — QEMU:** ✅ done.

**Step 4 — `git init`:** ✅ done.

**Acceptance:** the unsubstitutable `runCommand` probe above builds successfully on the
Mac (⬅ *this*, not the `hello` test, which is meaningless — see the correction above);
`qemu-system-aarch64 --version` prints ✅.

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
2. Software-rendering environment for the VM. **Use try-omarchy's verified set** (see
   Phase 6 for provenance) via `environment.sessionVariables`, gated behind the
   `bento-vm` host so a future bare-metal host doesn't inherit it:
   - `WLR_RENDERER_ALLOW_SOFTWARE = "1"` ← the current, correct variable (the older
     `WLR_NO_HARDWARE_CURSORS` guess is superseded),
   - `LIBGL_ALWAYS_SOFTWARE = "1"` (llvmpipe — we need this where try-omarchy doesn't,
     since we have no VirGL),
   - `OZONE_PLATFORM = "wayland"`, `ELECTRON_OZONE_PLATFORM_HINT = "wayland"`,
     `MOZ_ENABLE_WAYLAND = "1"`, `QT_QPA_PLATFORM = "wayland"` — needed by Chromium
     (Phase 5) and friends.
   Guest GPU packages: `mesa` plus `vulkan-swrast` (lavapipe) is sufficient — there is
   no separate virgl package, the driver lives inside mesa.
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

> **Phase 0 finding — settled, do not re-test:** Homebrew QEMU 11.1.1 **cannot** do
> VirGL. `-device help` offers only `virtio-gpu-pci` / `virtio-gpu-device` (no
> `virtio-gpu-gl-pci`), `-display help` offers only `none/curses/cocoa/dbus`, and
> `-display cocoa,gl=es` fails outright with *"OpenGL support was not enabled in this
> build of QEMU"*. The binary links no virglrenderer/epoxy/ANGLE. **Phase 3 must
> therefore plan for software rendering — it is not a choice, it is the only option
> with the stock host QEMU.**

Getting GL requires *replacing the host QEMU*, not reconfiguring it.

**What try-omarchy actually does (read from their source, 2026-08-30) — this is the
reference implementation for exactly our host + guest architecture:**

*Host side* — they build QEMU **10.2.50 from source** (`macos/build-qemu-gpu-runtime.sh`)
rather than using any stock binary:
- source/tap: `startergo/homebrew-qemu-virgl-kosmickrisp`, plus two of their own patches
  (`qemu-cocoa-dynamic-display.patch` — "publish the live backing display through
  virtio-gpu", which is what gives them live window resize and HiDPI; and
  `qemu-cocoa-product-identity.patch`);
- pinned deps: **virglrenderer 1.0.33** and **ANGLE 1.0.15** (ANGLE is the OpenGL-ES→Metal
  translator — the piece that makes GL possible at all now that macOS has dropped
  OpenGL), plus epoxy;
- configure: `--target-list=aarch64-softmmu --without-default-features --enable-system
  --enable-hvf --disable-tcg --enable-cocoa --enable-opengl --enable-virglrenderer
  --enable-pixman --enable-slirp --enable-sdl --enable-virtfs`;
- the built binary is **code-signed with `com.apple.security.hypervisor`** — they verify
  this at launch. (✅ Our Homebrew QEMU already has this entitlement, so hvf is fine for
  Phase 1; a self-built QEMU would need re-signing.)

*Runtime flags:*
```
-device virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080
-display cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=on,swap-opt-cmd=off
```
They **hard-fail** if `virtio-gpu-gl-pci` is absent — there is no software fallback in
their design. Ours is the reverse: software is the v1 baseline and GL is the upgrade.

*Guest side (directly portable to our NixOS config):*
- `/usr/lib/environment.d/90-try-omarchy.conf` sets `WLR_RENDERER_ALLOW_SOFTWARE=1`
  (note: **`WLR_RENDERER_ALLOW_SOFTWARE`, not `WLR_NO_HARDWARE_CURSORS`** — this
  supersedes the older name guessed in Phase 3 below), plus `OZONE_PLATFORM=wayland`,
  `ELECTRON_OZONE_PLATFORM_HINT=wayland`, `MOZ_ENABLE_WAYLAND=1`,
  `QT_QPA_PLATFORM=wayland`. Notably they set the software-renderer flag *even with*
  VirGL working — cheap insurance;
- guest packages are just `mesa` + `vulkan-swrast` (no special virgl package — the
  virgl Gallium driver ships inside mesa);
- they pass a kernel arg `omarchy.qemu_virgl=1` and key guest behaviour off it: hide the
  guest cursor (`cursor { invisible = true }`, because Cocoa draws the host cursor
  outside the guest scanout for zero-lag motion) and run a display-sync helper. They
  deliberately let **virtio-gpu EDID** carry the live window size and host refresh rate
  instead of hardcoding a monitor mode — that is the mechanism behind their
  "automatic guest resolution and HiDPI scale updates".

**Our fallback options if we don't want to build QEMU ourselves:**
[knazarov/homebrew-qemu-virgl](https://github.com/knazarov/homebrew-qemu-virgl) or
[popey/homebrew-QEMU-VirGL](https://github.com/popey/homebrew-QEMU-VirGL).
Re-verify with `-device help | grep gl` before touching the guest.
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

1. **Graphics on macOS-hosted QEMU** — the big one, and Phase 0 confirmed the bad case:
   the host QEMU has no GL at all, so Hyprland *will* run on llvmpipe in v1 and will
   feel slow. Accepted for v1; Phase 6 is the (failable) fix.
2. **aarch64 binary cache gaps** (Chromium, Ghostty) — never build these from source in
   the VM; substitute and report instead.
3. **Hyprland-in-VM env vars churn** — variable names for software rendering / cursors
   have changed across Hyprland versions; the implementing agent must check current
   docs rather than trust the examples here.
4. **Linux builder on macOS** — first-time setup can be fiddly (trust settings,
   `/etc/nix/machines`). Phase 0 is interactive for a reason.
5. **Walker on aarch64** — fallback to fuzzel is pre-authorized.
