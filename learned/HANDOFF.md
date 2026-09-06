# Handoff — v1 is done; next up, resolution and keyboard layout

Written 2026-08-30, at the end of the Phase 6 session. (Supersedes the Phase 5 → Phase 6
handoff; its findings live in `learned/phase-6.md`.)

**Phases 0–6 are all complete, including the stretch goal, and nothing is outstanding.**
The guest renders on the M4's GPU through VirGL, and Claude Code is logged in. Every
acceptance criterion in `PLAN-v1.md` is met.

Two new pieces of work are requested, described in full below. Neither is in `PLAN-v1.md`
— that plan is finished — so treat this file as their specification.

> **Update 2026-09-05.** `scripts/run-vm.sh` passes `full-grab=on`, and Bento's patched
> QEMU now routes Cmd+Space through a focus-scoped Carbon hotkey. A standalone probe proved
> that the earlier Accessibility/HID-event-tap diagnosis was wrong on this macOS release:
> even an authorised HID tap saw Command but not Space, whereas Carbon received the chord
> with no privacy permission after Spotlight hotkey 64 was temporarily disabled. Bento
> restores Spotlight on focus loss and exit and logs each forwarded chord. Cmd+K remains
> the keybinding-menu fallback. **Both tasks below are still untouched.** The full sequence
> and superseded conclusions are in `learned/keyboard-capture.md`, especially §13.

> **Update, 2026-09-06 — the reboot is done and it passed.** Hyprland is now configured in
> **Lua**, not hyprlang, and greetd launches it through **`start-hyprland`**; both were
> deprecation warnings printed across the top of the screen at every launch, and `.conf`
> support goes away in Hyprland 0.57. The machine was rebuilt with `bento rebuild boot` and
> rebooted **to prove greetd's autologin still lands in a desktop**, which is the one part
> no offline check could cover. **It does** — generation 51, no failed units, empty
> `configerrors`, 42 binds, `start-hyprland` the parent of `Hyprland --watchdog-fd 4`, and
> no banner in a `grim` capture. Super+drag moves and resizes windows, and both new
> `hyprctl eval` call sites answer `ok` against the live session. `learned/hyprland-lua.md`
> **§7 is the result**; §6 is the checklist it answers, and the rest of that file is the
> migration itself, including the two `hyprctl keyword` call sites that had to become
> `hyprctl eval` (§3) and why upstream's own `{ mouse = true }` bind option does not exist
> (§4). Also settled there: **`dkmac` loads** — `hyprctl devices` reports
> `active=Danish (Apple)` — which closes one of the two open questions below.
>
> **Two halves still want a hand at the host**, because neither can be driven from inside
> the guest: resize the QEMU window and confirm the guest scanout follows, and run
> `scripts/vm-screenshot.sh --type …` once from the host. The guest side of both is
> verified (§7 item 4). **Item 3 is now closed**: the guest follows a host window resize,
> which also settles Task 1's open question — no `qemu-cocoa-dynamic-display.patch` is
> needed. Task 1 is configuration only.

> **Update, 2026-09-06.** **Task 2 is largely done, and Task 1 has moved without being
> started.** Findings for both are in `learned/keyboard-layout.md`. The guest now has a
> custom `dkmac` layout (`modules/xkb/dkmac`), because `dk(mac)` turned out to be a stub
> over the *PC* Danish layout rather than Apple's; and it now runs at scale 2, because the
> scanout is **3840x2412** — not the 1920x1080 `scripts/run-vm.sh` asks for. That second
> one bears directly on Task 1's open question: the guest **did** follow the host window,
> so dynamic resize is no longer "unknown and the first thing to measure". Full-screen mode
> itself is still untouched. **One thing is now resolved and one is not**: `dkmac` has been
> seen to load (`learned/hyprland-lua.md` §7), and the `--type` trap flagged in Task 2 below
> is real rather than predicted.

## Paste this into the new session

> Two changes to bento (`/Users/chime/Workspace/Bento`), described in
> `learned/HANDOFF.md`: **(1) better resolution and a real full-screen window, the way
> try-omarchy does it, and (2) the ability to switch keyboard layout.**
>
> Read `PLAN-v1.md` and every `learned/phase-*.md` in full first — they record measured
> facts that contradict upstream documentation, and working from the official docs will
> waste your time or break things. `learned/phase-6.md` is the most relevant: it is the
> one that built the host QEMU these changes configure.
>
> Verify everything yourself against the running machine rather than reasoning about it.
> Note any substitution where a named option no longer exists. Finish by writing up what
> you measured, `./scripts/vm-sync.sh pull`, and committing.

---

## Task 1 — resolution and full-screen

The window is a fixed 1920×1080 in a Cocoa window on a **2880×1864 Retina** panel. Wanted:
a bigger, sharper guest, and a genuine full-screen mode like try-omarchy's.

### What is already established (do not re-derive)

`learned/phase-0.md` §3 read try-omarchy's source. Their runtime line is:

```
-device virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080
-display cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=on,swap-opt-cmd=off
```

**Every one of those display options exists in the QEMU we built** (10.1.2). Verified
against `qapi/ui.json` in the source tree rather than guessed, because it is not obvious
which are Cocoa-specific and which are not:

| Option | Where it is defined |
|---|---|
| `full-screen`, `show-cursor`, `window-close`, `gl` | base `DisplayOptions` — valid for *any* display type |
| `zoom-to-fit`, `zoom-interpolation`, `swap-opt-cmd`, `left-command-key`, `full-grab` | `DisplayCocoa` |

So the `-display` half needs **no patch**. `-display cocoa,help` is not implemented
("Help is not available for this option"), which is why the QAPI file is the authority.

### The cheapest win, and it may be most of the task

`hyprctl monitors` in the guest already reports these as available:

```
availableModes = ["1920x1080@60.00Hz", "5120x2160@50.00Hz", "4096x2160@50.00Hz",
                  "3840x2160@60.00Hz", … "640x480@59.94Hz"]
```

**The guest is not limited to 1920×1080 — it is choosing it**, because `run-vm.sh` passes
`xres=1920,yres=1080` and virtio-gpu's EDID makes that the *preferred* mode. Raising
`GPU_XRES`/`GPU_YRES` in `scripts/run-vm.sh` is a two-line change, and
`home/chime/hyprland.nix` can request a mode and a scale directly (it currently sets
neither, deliberately — `learned/phase-4.md` and `wallpaper.nix` both note that the monitor
name is emulated-hardware-specific and should not be hardcoded; `monitor = ,preferred,auto,1`
style entries keep that property).

Start here and measure before reaching for any patch. Note that HiDPI is a *separate*
question from resolution: a 2880×1864 guest at `scale=1` gives tiny text, and Hyprland's
`scale` plus `GDK_SCALE`/`QT_SCALE_FACTOR` is where that is answered.

### The open question — dynamic resize

try-omarchy's *automatic* resolution and HiDPI updates come from a **second, separate
patch**, `qemu-cocoa-dynamic-display.patch` — "publish the live backing display through
virtio-gpu" (`learned/phase-0.md` §3). **We did not apply it.** `scripts/patches/` holds
only the GL/texture-borrowing series.

But that series does touch `ui/cocoa.m`'s `updateUIInfo` and `resizeWindow`, which is the
same code path that publishes host window geometry to the guest via `dpy_set_ui_info` →
virtio-gpu EDID. **So it is genuinely unknown how much dynamic behaviour we already
have**, and the first experiment should settle it rather than assume:

```bash
# boot with try-omarchy's display line, then resize/fullscreen the window by hand
# and watch whether the guest follows:
ssh -p 2222 chime@localhost \
  'export XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr | head -1); \
   hyprctl monitors -j | jq -r ".[0] | \"\(.width)x\(.height)@\(.refreshRate)\""'
```

If the guest already follows the window, this task is configuration only. If it does not,
the patch is the next step — and it is much cheaper now than it was, because we already
build QEMU from source (`scripts/build-qemu-gl.sh`, ~4 minutes, one target). Vendor it into
`scripts/patches/` with a pinned sha256 the way the existing one is, and note that
try-omarchy's copy is served from a *branch* URL that can move.

### Two things that will bite

- **`show-cursor=on` interacts with the guest cursor.** try-omarchy pairs it with
  `cursor { invisible = true }` in Hyprland, because Cocoa composes the host cursor
  *outside* the guest scanout for zero-lag motion — otherwise you get two pointers. Our
  `home/chime/hyprland.nix` currently sets `no_hardware_cursors` off the
  `softwareRendering` option, and `hardwareCursorsInUse` is now `true`
  (`learned/phase-6.md` §7), so this needs measuring rather than copying.
- **Changing `xres`/`yres` does not renumber the PCI slots**, so `--reset-vars` is not
  needed — `learned/phase-6.md` §2 established this for the device swap, and a property
  change is strictly less invasive. A UEFI `Shell>` prompt would still be the symptom if
  something *did* change the topology.

Screenshots will change size with the resolution; `scripts/screen-colors.py` prints the
dimensions it read, so use it to confirm rather than trusting the flag.

---

## Task 2 — switch keyboard layout

Currently `us` and nothing else. Measured in the guest:

```
qemu-qemu-usb-keyboard   layout=us   active=English (US)
System Locale: LANG=en_US.UTF-8, LC_TIME=en_DK.UTF-8, LC_MONETARY/LC_PAPER/LC_MEASUREMENT=da_DK.UTF-8
VC Keymap: (unset)      X11 Layout: us
```

The locale is already half-Danish, so `us,dk` is the obvious pair — **confirm which
layouts are actually wanted before building it.**

Where the pieces live:

| Layer | Where | Note |
|---|---|---|
| Hyprland (the real one) | `home/chime/hyprland.nix`, `input.kb_layout` | `kb_layout = "us,dk"` plus `kb_options = "grp:alt_shift_toggle"` or `grp:win_space_toggle` |
| An explicit keybind | same file | `hyprctl switchxkblayout <device> next` — the device name is `qemu-qemu-usb-keyboard` here, but hardcoding an emulated device name is exactly the coupling this repo avoids; `current` / `all` forms exist |
| Showing which is active | `home/chime/waybar.nix` | waybar's `hyprland/language` module; theme it from `home/chime/theme/` like every other module, and mind that glyphs are **codepoints, never pasted characters** (`learned/phase-4.md` §1) |
| The text console | `modules/core.nix` | `console.keyMap` is unset. tty1 matters here — quitting Hyprland with `Super+Shift+Q` drops you to `agreety` on it (`learned/phase-3.md` §4) |

### The trap, and it is a real one

**Switching the layout will change what `scripts/vm-screenshot.sh --type` produces.** That
tool drives QEMU's emulated keyboard by *key name* — `sendkey a`, `sendkey shift-4` — which
are physical US positions. The guest then interprets those positions through whatever xkb
layout is active. So with `dk` selected, `--type` will silently type different characters,
and the symbols are what move (`learned/phase-3.md` §1 documents the US-position
assumption: `$` is `shift-4`, `_` is `shift-minus`).

This is the agent's own eyes and hands, used by every graphical test in Phases 3–6. Any
default that leaves a non-US layout active at login will make those tests lie. **Leave `us`
first in the list**, and if that is not what you want day to day, say so plainly in the
commit rather than letting a future session discover it through a test that fails for no
visible reason.

---

## State to be aware of

**In sync at the keyboard-capture commit**, host and VM, both trees clean — confirm with
`./scripts/vm-sync.sh status` rather than trusting this file. `bento doctor` over ssh
answers everything else in one screen and is still the right first command:

```bash
ssh -p 2222 chime@localhost 'cd ~/bento && bento doctor'
```

**The bento VM was shut down** at the end of the keyboard-capture session, cleanly, so that
restarting the terminal would not power-cut it — QEMU had been launched from a shell under
the agent's own process tree, which made it a descendant of the terminal application. Boot
it again with `./scripts/run-vm.sh`. `pgrep -fl qemu-system-aarch64` tells you whether it is
up and in which mode — a path under `~/.local/state/bento/qemu-gl` means GL. If the window
is locked,
that is hyprlock on hypridle's 30-minute timer: the box reading "Locked" is the password
field, the password is `bento`, and there is no cursor until you type.

**Claude Code is logged in**, and `build-image.sh` would undo that — it replaces the disk.
`~/.claude` survives every `bento rebuild` and no re-image.

**`artifacts/bento.qcow2` is the live disk with no snapshot behind it.** `build-image.sh`
replaces it and `bento gc --all` deletes the generations you could roll back to. Treat both
as destructive; `./scripts/vm-sync.sh pull` first.

**Phase 6's host footprint** — the only non-declarative part of this repo:

| What | Where | Undo |
|---|---|---|
| GL QEMU 10.1.2 | `~/.local/state/bento/qemu-gl` (36 MB) | `rm -rf`, then `--no-gl` |
| ANGLE + epoxy + virglrenderer | Homebrew, `startergo/qemu-virgl` tap | `brew uninstall virglrenderer libepoxy-angle libangle && brew untap startergo/qemu-virgl` |

`./scripts/build-qemu-gl.sh --check` reports it. The linux-builder is **not** running and
is needed only to rebuild the *image*.

### Where to do this work

Task 1 is **host** work — it is `scripts/run-vm.sh`, QEMU flags and possibly a QEMU patch,
none of which exist inside the guest. Task 2 is almost entirely **guest** work and is a
good fit for `cd ~/bento && claude` on the machine itself, where `hyprctl` and the live
session are simply there instead of behind three exported variables per ssh command.

Do not run both at once against the same files: the host and guest are two real git
repositories and `vm-sync.sh pull` is fast-forward only by design, so divergence is
refused rather than merged.

## The findings most likely to bite, whichever task you start with

Full detail in `learned/phase-6.md`; these are the ones that cost real time.

1. **A screenshot that comes back all black is the camera, not the desktop** (§3). Under
   VirGL, QMP `screendump` copies the pixman surface while the scanout is a GL texture, so
   it writes a valid PNG of nothing and reports no error. `scripts/vm-screenshot.sh`
   handles this by using `grim` in the guest when it sees a GL device — but anything
   talking to QMP directly gets lied to. Sanity-check with
   `./scripts/screen-colors.py <png> --hist`; `#000000 100.0%` is the tell. Corollary:
   **`--no-gl` is the mode to debug a boot failure in**, because grim needs a running
   compositor and cannot photograph a UEFI prompt.
2. **This GPU is faster but *narrower* than llvmpipe** (§5). ANGLE is GL ES, so there is
   no desktop GL core profile at all. That is why ghostty carries a
   `LIBGL_ALWAYS_SOFTWARE` wrapper scoped to its own binary in `home/chime/ghostty.nix`.
   Anything new that cannot get a GL context is probably hitting the same wall; the same
   wrapper is the fix, **scoped to that binary, never session-wide**.
3. **`bento.desktop.softwareRendering` cannot tell you whether there is a GPU** (§4). It is
   fixed when the system is built; the GPU appears when the VM is launched, and one image
   serves both. Anything that must be right in both modes has to be unconditional — which
   is why `GSK_RENDERER=cairo` is still set. Do not re-gate it.
4. **`| grep -q` under `set -o pipefail` reports failure on success** (§9), and macOS `ps`
   truncates without `-ww`. Both cost time in Phase 6 and both fail silently.
