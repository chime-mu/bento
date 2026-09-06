# Hyprland's Lua config, and `start-hyprland`

Written 2026-09-06, in the VM, against Hyprland 0.56.2. This is both the record of a
migration and the **checklist for the reboot that verifies it** — §6 is what to do first if
you are reading this after that reboot.

Two messages printed across the top of the screen at every launch prompted it:

> You are using the .conf config format, support for which will be removed in Hyprland 0.57.

> Hyprland was started without start-hyprland. This is strongly discouraged unless you are
> in a debugging environment.

Both are real deprecations rather than cosmetic noise, and the first has a version number
on it. Everything below was measured against the binary actually installed here —
`Hyprland --verify-config`, a nested Hyprland running the generated config beside the live
session, and `objdump` where the two disagreed with upstream's own example config.

## 1. `--verify-config` executes the Lua, and is the cheapest tool here

`Hyprland --verify-config -c FILE` does not run a compositor and does not touch the live
session. For a `.lua` config it *executes* the file, so it catches unknown config keys
(`unknown config key 'general.bogus_setting'`), bad dispatcher arguments
(`hl.window.swap: invalid direction "bogus" (expected left/right/up/down)`) and plain Lua
errors, with line numbers. Use it on the file home-manager generates:

```sh
nix eval --raw '.#nixosConfigurations.bento-vm.config.home-manager.users.chime.xdg.configFile."hypr/hyprland.lua".text' > /tmp/h.lua
Hyprland --verify-config -c /tmp/h.lua
```

## 2. A nested Hyprland is a real test bed

`WAYLAND_DISPLAY=wayland-1 Hyprland -c /path/to/config.lua` starts a second compositor as a
client of the running one, with its own instance signature. `hyprctl --instance <sig> …`
then answers about *that* instance, so `binds`, `getoption` and `configerrors` can be
diffed against the live session. That is how the translation below was checked value by
value: 42 binds in both, and every option identical apart from the type label the Lua
config manager prints (`bool: true` where the legacy parser said `int: 1`, `gradient data`
where it said `custom type`).

**Strip home-manager's `hl.on("hyprland.start", …)` hook before running one.** It calls
`systemctl --user stop/start hyprland-session.target`, which would act on the *real*
session's units.

## 3. `hyprctl keyword` and `hyprctl eval` are mutually exclusive

This is the change with the widest blast radius, and neither half of it is announced
anywhere near the config file:

| | legacy (`.conf`) | lua |
|---|---|---|
| `hyprctl keyword input:kb_layout us` | works | `keyword can't work with non-legacy parsers. Use eval.` |
| `hyprctl eval 'hl.config({...})'` | `eval is only supported with the lua config manager` | works |
| `hyprctl getoption input:kb_layout` | `str: us` | `str: us` |
| `hyprctl dispatch exit` | works | evaluated as Lua — wants `hyprctl dispatch 'hl.dsp.exit()'` |

`eval` answers exactly `ok`, or `error: …` with exit status 7, so a caller that already
checked for `ok` needs no new error handling. The two callers in this repo both moved:

- `home/chime/display-sync.sh` — `hl.monitor({ output = "", mode = …, position = "auto", scale = … })`
- `scripts/vm-screenshot.sh` — `hl.config({ input = { kb_layout = … } })`, wrapped in single
  quotes because `guest_hyprctl` interpolates into a *remote* shell where `(` is syntax.

`getoption` surviving unchanged is what lets vm-screenshot still read the layout back with
`awk '/^str:/'`.

## 4. `{ mouse = true }` is not a bind option, and is not needed

Upstream's shipped `share/hypr/hyprland.lua` writes the drag binds as

```lua
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
```

That option does not exist. Disassembling `hlBind` gives the complete set of names it reads
— `locked`, `release`, `repeating`, `long_press`, `click`, `drag`, `transparent`,
`ignore_mods`, `non_consuming`, `dont_inhibit`, `submap_universal`, `catchall`,
`allow_input_capture`, `device`, `inclusive`, `desc`, `description`, `list` — and `mouse`
is not among them. Anything else is silently ignored, and `hyprctl binds -j` confirms the
flag stays `false` where the legacy `bindm` set it `true`.

It is also unnecessary. The press-and-hold behaviour belongs to the dispatcher:

- `hl.dsp.window.drag()` unconditionally pushes `dsp_mouseDrag` — the same action legacy
  `bindm = …, movewindow` reached through `Config::Actions::mouse`.
- `hl.dsp.window.resize()` branches on `lua_gettop`: **no arguments** gives
  `dsp_mouseResize`; pass a size and you get the geometric `resizeactive` instead.
- The drag ends on button-up through `CKeybindManager::ensureMouseBindState()`, which is
  called from `onKeyEvent` and `onMouseEvent` and inspects only the layout's drag
  controller. It never looks at the keybind.

## 5. The rest of the translation

- `settings.<name>` renders as `hl.<name>(...)`; a list renders one call per element;
  `_args` renders a multi-argument call; `_var` renders a Lua `local`. Locals are emitted
  first, then everything else alphabetically.
- Every argument goes through `lib.generators.toLua`, so a Nix string arrives *quoted*.
  Anything Lua must evaluate — a local, a dispatcher — has to be `lib.generators.mkLuaInline`.
- hyprlang's `$mod` became a `local mod`, so `home/chime/walker.nix`, which reads the
  terminal back out of the evaluated config, now wants `settings.terminal._var`. **A
  cross-file read like that is the failure mode to watch for**: it is invisible until
  `nix flake check` throws `attribute '"$terminal"' missing`.
- The two-stop border gradient became `col.active_border = { colors = [...]; angle = 45; }`
  where hyprlang ran the stops and the angle together into one string.
- `bind`/`bindm` collapsed into one `bind` list (see §4). `fullscreen, 0` became
  `hl.dsp.window.fullscreen({ mode = "fullscreen" })`; `layoutmsg` became `hl.dsp.layout`.
- hyprlock, hypridle and hyprpaper keep their own `.conf` files. The deprecation is
  Hyprland's config parser, not hyprlang the language.
- A stale `~/.config/hypr/hyprland.conf` would **not** shadow the new file — Hyprland
  prefers `hyprland.lua` when both exist. Verified, so it is one thing not to worry about.

## 6. Verifying the reboot

`bento rebuild boot` was run and the machine rebooted **to check that greetd's autologin
still lands in a desktop**, because that is the one thing neither `--verify-config` nor a
nested instance can prove: `initial_session` now launches `start-hyprland --path
/run/wrappers/bin/Hyprland` rather than the wrapper directly.

If you are picking up after that reboot, in order:

```sh
bento doctor                     # generation, failed units
systemctl status greetd          # should be active, and not restarting
hyprctl version                  # a session exists at all
hyprctl configerrors             # must be empty
hyprctl binds | grep -c '^bind'  # 42
ps -o args= -p "$(pgrep -x start-hyprland)"   # the watchdog is the parent

# The log is per-instance, not in $HOME. Compare against ~20 ERR on a GL boot — see §7;
# the "~12 KB and 5 ERR" from phases 3–5 predates the GPU and is not a baseline here.
grep -c ERR "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.log"
```

Then the four things that were only ever checked out-of-session:

1. **No banner.** Neither deprecation message across the top of the screen. This is the
   whole point of the change.
2. **Super+Left-drag moves a window, Super+Right-drag resizes one.** §4 is an argument from
   disassembly, not an observation; this is the observation.
3. **The display synchronizer.** `systemctl --user status bento-display-sync`, then resize
   the QEMU window and confirm the guest follows. Its `hyprctl eval` path is new.
4. **`scripts/vm-screenshot.sh --type …` from the host.** It sets and restores the keyboard
   layout through `hyprctl eval` now. A failure here is quiet — the screenshot still
   arrives, with the wrong characters typed into it.

If greetd does not come up, ssh still does (`sshd` is enabled and independent of the
desktop), and generation 50 is the last one built before this change:

```sh
sudo nixos-rebuild switch --rollback     # or pick generation 50 in systemd-boot
```

## 7. What the reboot actually showed

Rebooted 2026-09-06 09:53 into generation 51. **greetd's autologin lands in a desktop**,
which was the whole reason for the reboot:

```
861  greetd --config …/greetd.toml          active (running), not restarting
959  start-hyprland --path /run/wrappers/bin/Hyprland
995  └─ Hyprland --watchdog-fd 4
```

`start-hyprland` is the parent, so the watchdog is in the loop rather than bypassed.
`bento doctor` reports no failed units, system or user. `hyprctl configerrors` is empty and
`hyprctl binds | grep -c '^bind'` is 42 — the same count the nested instance in §2 gave.

Of the four out-of-session items:

1. **No banner** — confirmed from a `grim` capture of the live desktop. Neither deprecation
   line is across the top.
2. **Super+drag** — confirmed, and §4's disassembly argument holds. Method below, because
   it is reusable: a floating window at `[900,600] 500x350` went to `[1100,700]` under a
   Super+Left-drag of exactly +200,+100, and 500x350 → 600x410 under a Super+Right-drag of
   +100,+60 from the bottom-right quadrant with `at` unchanged. `hyprctl binds -j` still
   reports `mouse: false` on both binds while they behave as drags, which is exactly what
   §4 predicted.
3. **The display synchronizer** — `bento-display-sync` is active, and its new
   `hyprctl eval 'hl.monitor({…})'` answers `ok`. The live scanout is **3840x2412 @ scale
   2**, not the 1920x1080 `scripts/run-vm.sh` asks for, so the eval path demonstrably ran
   and applied at login. Restarting the unit re-applies cleanly. *The one half still
   unverified is the host-side event*: nobody has resized the QEMU window since the reboot,
   and that cannot be done from inside the guest.
4. **The keyboard-layout path** — the guest half is confirmed:
   `hyprctl eval 'hl.config({ input = { kb_layout = "us" } })'` answers `ok`,
   `getoption input:kb_layout` follows, and `hyprctl devices` shows `active_keymap` moving
   `Danish (Apple)` → `English (US)` and back on both `qemu-virtio-keyboard` and
   `power-button`. *Still unverified*: `scripts/vm-screenshot.sh --type` end to end, which
   only runs from the host.

Also settled in passing, and it was the other open question in `learned/HANDOFF.md`:
**`dkmac` loads.** `hyprctl devices` reports `layout=dkmac active=Danish (Apple)` on both
keyboards, so `XKB_CONFIG_ROOT` is reaching the compositor in a session started by greetd.

### The ERR count is 20, and the ~5 baseline is stale

§6 says to compare against "~12 KB and 5 ERR". This session is 77 KB and 20 ERR, and the
difference is **not** the Lua migration — every ERR is from the driver layer, below the
config parser:

| Count | Message |
|---|---|
| 4 | `aquamarine: drm: Cannot commit when a page-flip is awaiting` |
| 3 | `[EGL] eglCreateContext … EGL_BAD_MATCH: dri2_create_context` |
| 2 | `CDRMRenderer: eglCreateContext failed with GLES 3.2, retrying GLES 3.0` |
| 2 | `Couldn't get the gamma_size prop` |
| 2+2+2 | XCursor/Hyprcursor theme fallback, three lines |
| 1+1+1 | `Wayland backend cannot start … enabling fallbacks … erasing` |

The GLES 3.2 → 3.0 retry is `learned/phase-6.md` §2 in the log — ANGLE is GL ES, so the
higher context is refused and the fallback succeeds. The wayland-backend line is Hyprland
probing for a parent compositor before falling through to DRM. **The 5-ERR figure was
measured in phases 3–5, before phase 6 put a GPU under this session**, so it is not a
baseline for a VirGL boot. The size difference is the same story: 63 of the extra lines are
`EGL: | with modifier INVALID` at DEBUG.

Use ~20 ERR on a GL boot as the number to compare against from here.

### Driving the compositor's own input from inside the guest

There was no way to test a mouse bind here — `wtype`, `ydotool` and `wlrctl` are all absent
from the image, and `--type` in `scripts/vm-screenshot.sh` drives QEMU's *emulated* keyboard
from the host, which cannot press a mouse button. What works, and leaves nothing behind:

```sh
sudo modprobe uinput                                    # /dev/uinput exists, module is not loaded
YD=$(nix build --no-link --print-out-paths nixpkgs#ydotool)/bin
sudo -b "$YD/ydotoold" --socket-path=/tmp/ydotool.sock --socket-own=1000:100
export YDOTOOL_SOCKET=/tmp/ydotool.sock
"$YD/ydotool" mousemove --absolute -x 1150 -y 775       # verify with `hyprctl cursorpos`
"$YD/ydotool" key 125:1                                 # Super down
"$YD/ydotool" click 0x40                                # left button down (0x41 = right)
"$YD/ydotool" mousemove --absolute -x 1350 -y 875       # …in ~10 steps
"$YD/ydotool" click 0x80; "$YD/ydotool" key 125:0       # up, Super up
```

Hyprland picks the device up as `ydotoold-virtual-device-1` (pointer) and
`ydotoold-virtual-device` (keyboard) and it disappears from `hyprctl devices` when
`ydotoold` is killed.

**Use `--absolute` for every step of a drag.** Relative `mousemove` during a held button
sent the cursor somewhere unrelated — 20 × `-x 10 -y 5` from `1150,775` landed at
`1126,1205` against the bottom edge, and the window never moved. ydotoold's uinput device
carries both REL and ABS axes, and mixing them mid-drag is what breaks it. With absolute
steps throughout, the window tracks the cursor delta exactly.

Note the coordinates are **logical**: the scanout is 3840x2412 but `scale = 2`, so the
addressable space is 1920x1206 and `hyprctl cursorpos` answers in those units.

### `--type here` is not a discriminating test for item 4

A host-side `--type` run after this reboot put `here` into the guest and the characters
arrived correctly, which proves the ssh plumbing, the descriptor read and the screendump
all work. It does **not** prove the layout set/restore did anything, because **`dk` and
`us` place a–z identically** — `dk` takes its alphabetic rows from `latin`, and only the
symbols move. `here` comes out as `here` whether the active layout is `us` or `dkmac`, so a
silently failed `set_guest_layout us` looks exactly like a successful one.

The discriminating keys are in xkeyboard-config's own `symbols/dk` versus `symbols/us`:

| key | `sendkey` name | `us` | `dk` (and so `dkmac`) |
|---|---|---|---|
| `<AE11>` | `minus` | `-` | `+` |
| `<AE11>` shifted | `shift-minus` | `_` | `?` |
| `<AE04>` shifted | `shift-4` | `$` | `¤` |

So the test that actually exercises the trap is a `--type` string containing `-`, `_` or
`$`. If the layout switch is working, `-` arrives as `-`; if it silently failed, `-`
arrives as `+`. **Any future `--type` regression test should use one of those characters
rather than letters.**

The guest half is independently confirmed regardless (§7 item 4): the `eval` answers `ok`
and `hyprctl devices` shows `active_keymap` flipping. What is unproven is only that the
host script's call reaches it.
