# What Phase 4 taught us

**Date:** 2026-08-30 · **Host:** Apple Silicon MacBook (M4), macOS 26.5.2 · **Guest:** NixOS
`26.11.20260828.83199d0`, Hyprland **0.56.2**, waybar **0.15.0**, walker **2.17.0** +
elephant **2.22.0**, mako **1.11.0**, hyprlock **0.9.6**, hypridle **0.1.8**, swaybg
**1.2.2**, foot **1.27.0**, mesa **26.2.1**, `aarch64`
**Outcome:** ✅ Phase 4 complete — a themed bar, a working launcher, themed notifications, a
lock screen and a wallpaper, all verified off the QEMU scanout with nobody at the monitor.

Findings log for Phase 4: the Omarchy visual foundations. Everything here was measured
inside the running VM. Where it contradicts `PLAN-v1.md`, the earlier learned files or
upstream documentation, that is called out.

## Acceptance — verified

| Criterion | Result | How |
|---|---|---|
| Screenshot of the desktop shows a themed bar | ✅ waybar: workspaces, clock, cpu/memory/network with Nerd Font glyphs, Tokyo Night | QMP `screendump` |
| Launcher opens with Super+Space | ✅ walker, themed, listing desktop entries | `--key meta_l-spc`, then a screenshot |
| `notify-send` shows a themed notification | ✅ normal *and* critical, different borders | `notify-send` over ssh, then a screenshot |
| *(beyond the criteria)* an app launches **from** the launcher | ✅ `Super+Space`, type `htop`, Return → htop in a foot window | `--key` / `--type` |
| *(beyond the criteria)* the lock screen authenticates | ✅ `loginctl lock-session 1` → hyprlock; password typed on the emulated keyboard; `LockedHint=no` | `--type bento --key ret` |
| `nix flake check` still green | ✅ exit 0 in 11 s, natively in the guest | — |
| Compositor still healthy | ✅ `hyprland.log` 12 KB, 5 `ERR` — the same clean baseline as Phase 3 | `hyprctl configerrors` empty |

**Nothing was left for a human to confirm.** Nine `bento rebuild`s, no image rebuild, no
linux-builder.

**Four substitutions from PLAN-v1 §4, all deliberate:**

1. **swaybg replaces hyprpaper** — hyprpaper 0.8.4 segfaults on virtio-gpu, reproducibly.
   §3.
2. **`GSK_RENDERER=cairo` is set** after Phase 3 concluded that `softwareRendering` should
   set no environment variables. It is not one of the two variables Phase 3 ruled out, and
   without it GTK 4 draws nothing at all. §2.
3. **foot is themed here** rather than left for Phase 5, and moved out of
   `environment.systemPackages` into home-manager. §7.
4. **walker was *not* substituted.** PLAN-v1 risk #5 pre-authorises falling back to fuzzel;
   it was not needed — walker is in the aarch64 binary cache. §4.

---

## 1. The bug that a screenshot cannot see: PUA characters do not survive the trip

The waybar config was written with Nerd Font glyphs pasted straight into the Nix string —
`format = " {usage}%"` — which is how every waybar config on the internet is written. The
bar came up rendering `11%` with a space in front of it and no icon.

The glyphs were not mis-rendered. **They were not in the file.** By the time the config
reached the guest, `format = " {usage}%"` contained a space and nothing else: the
codepoints had been silently dropped somewhere between writing the source and the bytes on
disk. `fc-list ":charset=f085"` confirmed the font had the glyph all along.

They are U+F085 and friends — the **Private Use Area**. Nothing validates them, no tool
warns, and every layer they pass through (an editor, a terminal, a diff, a patch, an
agent's file writer) is entitled to normalise or drop them.

The fix is to stop writing the character and start writing the codepoint. Nix string
literals have no `\uXXXX` escape; JSON does, and `builtins.fromJSON` is one call away:

```nix
glyph = code: builtins.fromJSON ''"\u${code}"'';
icons.cpu = glyph "f085";   # nf-fa-cogs
```

`nix eval --raw` on that emits `ef 82 85` — U+F085, correct UTF-8. It is in
`home/chime/theme/default.nix`, and it is strictly better than the pasted form for a second
reason: a reader whose terminal has no Nerd Font can still tell which glyph was meant.

> **Generalised lesson.** Phases 0–3 each recorded a version of *"a setting that produces a
> working screen is not a setting that works"*. This is the mirror image: **a source file
> is not necessarily the bytes you typed.** When a config produces the right *layout* with
> the wrong *content*, check the bytes before you check the program.

## 2. GTK 4 has no working renderer here, and it fails by drawing nothing

`learned/phase-3.md` §8 says, flatly: *"No software-rendering environment variables."* This
phase sets one. The reasoning behind that rule is intact — the exception was measured, and
the rule's own subject (`WLR_RENDERER_ALLOW_SOFTWARE`, `LIBGL_ALWAYS_SOFTWARE`) is still
unset.

Super+Space bound correctly (`hyprctl binds` agreed), walker started, elephant answered it,
and `hyprctl layers` showed a walker layer surface at the right size:

```
Layer af9436e93c20: xywh: 0 0 1920 1080, a: 1, namespace: walker, pid: 14135
```

and the screen showed the wallpaper. The window was there, mapped, focused, and completely
transparent.

GTK 4 renders through GSK, which tries Vulkan first. lavapipe is installed, but the Vulkan
loader also finds mesa's **radv** ICD, which probes virtio-gpu as an AMD card:

```
radv/amdgpu: failed to initialize device.
Vulkan: radv_physical_device.c:2597: failed to query GPU info (VK_ERROR_INITIALIZATION_FAILED)
```

It then falls back to its GL renderer, which hits the same `DRI2: failed to create screen`
that aquamarine survives — aquamarine retries on `/dev/dri/renderD128` and reaches llvmpipe
(`phase-3.md` §2); GSK does not. What it does instead is carry on with no renderer.

Measured four ways, each read off the actual scanout:

| `GSK_RENDERER` | Result |
|---|---|
| unset | layer surface mapped 1920×1080, nothing drawn |
| `vulkan` | nothing drawn |
| `gl` | nothing drawn |
| **`cairo`** | **the launcher, correct and themed** |

So `environment.sessionVariables` gains `GSK_RENDERER = "cairo"`, gated behind
`bento.desktop.softwareRendering`. Waybar is unaffected — GTK 3 draws through cairo
already — and this is one of the lines Phase 6 deletes if it ever lands real GL.

> The difference between this and the two variables Phase 3 rejected is not that one is
> "allowed" and the others are not. It is that those two were **copied from another
> distribution's guest overlay** and never checked here, and this one was measured on this
> machine against the alternative of a launcher nobody can see.

## 3. hyprpaper 0.8 cannot run on virtio-gpu — and its config language changed too

Two separate problems, in sequence, and the first one hides the second.

### 3.1 `preload` and `wallpaper = <monitor>,<path>` no longer exist

Every hyprpaper example — the wiki, the man page, every dotfiles repo — is:

```
preload = ~/wall.png
wallpaper = ,~/wall.png
```

In 0.8.4, `src/config/ConfigManager.cpp` registers **no `preload` value and no `wallpaper`
handler**. `wallpaper` is a hyprlang *special category* keyed on `monitor`, so the
configuration is a block:

```
wallpaper {
  monitor = *
  path = /nix/store/…-tokyo-night.png
}
```

Preloading is implicit. home-manager already models this correctly — a **list of attrsets**
produces the block form; a list of strings produces the dead one — but its option
documentation shows both, and the old spelling is what you reach for.

Nothing fails. The old lines are parsed, ignored, and hyprpaper runs happily with nothing
to draw, logging one line at DEBUG on a unit that reports `active (running)`:

```
Monitor Virtual-1 has no target: no wp will be created
```

And when you do get the syntax right, note that the monitor must be `*` and not the empty
string that also documents as a wildcard. hyprpaper's own source says why:

```c
// "*" is preferred since hyprlang's special category system doesn't properly
// return entries with empty string keys from listKeysForSpecialCategory().
```

### 3.2 …and then it segfaults

With a config it actually understands, hyprpaper dies within a second of the compositor
configuring its layer surface:

```
ERR from aquamarine ]: GBM: Failed to allocate a GBM buffer: bo null
ERR from aquamarine ]: Couldn't allocate a gbm buffer with size [1920, 1080] and format AB4H
ERR from aquamarine ]: Swapchain: Failed acquiring a buffer
hyprpaper.service: Main process exited, code=dumped, status=11/SEGV
```

`AB4H` is `DRM_FORMAT_ABGR16161616F` — half-float colour. hyprpaper 0.8 draws through
**hyprtoolkit**, which asks aquamarine's GBM allocator for that format; virtio-gpu does not
offer it, `gbm_bo_create` returns null, and `CWaylandBuffer`'s constructor dereferences the
null on the first `zwlr_layer_surface_v1.configure`. It is a missing null check upstream,
not something a configuration can avoid: `AQ_NO_MODIFIERS=1` and `AQ_FORCE_LINEAR_BLIT=1`
— the aquamarine knobs `phase-3.md` §2 points at — were tested A/B and change nothing.

**swaybg is the substitute**, and it is a better architectural fit than a compromise: it is
`wl_shm` + cairo, so it hands the compositor a shared-memory buffer and lets *the
compositor* be the one that owns a renderer. On a machine whose defining property is that
it has no GPU, that is the right shape. It needs a hand-written systemd user unit
(no home-manager module), which is nine lines.

> Worth generalising: **the Hypr* ecosystem's newer tools assume a real GPU.** hyprpaper,
> and anything else built on hyprtoolkit, is a candidate for the same crash. hyprlock is
> *not* — it has its own renderer and works fine (§5).

## 4. walker is fine on aarch64 — risk #5 does not fire

PLAN-v1 risk #5 pre-authorises falling back to fuzzel. Measured before building anything:

```
$ nix build --dry-run nixpkgs#walker
these 7 paths will be fetched (9.4 MiB download, 31.6 MiB unpacked)
```

Zero built. Same for elephant (18 paths, 243 MiB), waybar, mako, hyprlock, hypridle,
swaybg and `nerd-fonts.caskaydia-mono`. Nothing in this phase compiled anything in the VM,
which is what PLAN-v1 risk #2 asks for.

**Every pre-2.0 walker guide is wrong about its architecture.** walker 2.x is two
processes: `walker` is only the GTK4 front end, and **elephant** is the daemon that knows
what a desktop entry, a calculator expression or a running window is. Without it the
launcher opens and says *"Waiting for elephant..."*. home-manager models the relationship
(`services.walker.enableElephantIntegration` defaults to `services.elephant.enable` and
adds the `Requires=`/`After=`) but will not enable elephant for you.

Two more things read out of walker's source rather than guessed:

- **A theme directory need only contain the files it overrides.** `setup_theme_from_path`
  starts from the embedded default theme and replaces only what it finds, so shipping
  `style.css` alone is complete and the stock XML layouts stay.
- **…but the CSS is replaced, not layered.** `setup_css` loads the embedded default *only*
  when the theme has no stylesheet. A theme that sets three colours gets three colours and
  no other styling at all. `home/chime/walker.nix` therefore carries a full stylesheet,
  following the structure of walker's own `resources/themes/default/style.css`.
- A partial `config.toml` **is** safe: walker deserialises the user file into a
  `PartialWalker` with every field optional and merges it over the defaults.

`elephant.override { enabledProviders = [...] }` exists and is tempting for the 243 MiB.
It was not used: it turns a substituted package into a Go build inside the VM to save disk
on a 60 G image. Providers are narrowed at query time instead, in `settings.providers`.

## 5. hyprlock: two settings that make it look broken when it is not

Both cost time, both were diagnosed from a screenshot, and one of them fooled us
completely.

**`general:grace` no longer exists** in 0.9.6. The full set is `text_trim`, `hide_cursor`,
`ignore_empty_input`, `immediate_render`, `fractional_scaling`, `screencopy_mode`,
`fail_timeout`. The error is printed once, to stderr, and inherited by *hypridle's* journal
because hypridle is what spawned hyprlock — so `journalctl --user -u hyprlock` shows
nothing and the unit list has no `hyprlock.service` in it at all.

**`fade_on_empty` defaults to on**, with `fade_timeout = 2000`. Take a screenshot more than
two seconds after the screen locks and there is a wallpaper, a clock, and **no password
field**. The first conclusion drawn from that screenshot was "the input field failed to
render under llvmpipe" — a plausible, entirely wrong hypothesis that a `--type` of the
password immediately disproved, because the field faded straight back in. It is set to
`false`: on a machine inspected through screenshots, a widget that disappears on a timer is
a widget that will be reported as missing.

Three things that *did* work first time, and are worth not re-testing:

- **PAM.** `security.pam.services.hyprlock = { }` in `modules/desktop.nix` is the only line
  taken from nixpkgs' `programs.hyprlock` module — enabling the whole module would also
  install hyprlock system-wide and turn on the NixOS `services.hypridle`, racing the
  home-manager one. hyprlock's default `auth:pam:module` is `hyprlock`, so the names match.
  Verified end to end: password typed on the emulated keyboard, `LockedHint=no` afterwards.
- **hyprlock renders fine on llvmpipe.** It does not use hyprtoolkit.
- **hypridle's logind integration.** `loginctl lock-session` → `Wayland session got locked`
  → `lock_cmd`. But **`loginctl lock-session` with no argument locks the caller's session**,
  and over ssh that is the ssh session, not the desktop: the first test looked like a total
  failure and was testing the wrong session. `loginctl lock-session 1` works.
  `hyprctl` reports session `1` on `tty1`; `loginctl list-sessions` names it.

**No DPMS listener, on purpose.** On real hardware, blanking the panel after the lock is
right. Here "the monitor" is a QEMU scanout that an agent photographs, and switching it off
makes the only window onto this machine go black — indistinguishable, in a screenshot, from
a guest that has hung.

## 6. mako needs a systemd unit that home-manager does not write

`services.mako.enable` installs the package and copies mako's D-Bus service file into
`~/.local/share/dbus-1/services`. That file says:

```
Name=org.freedesktop.Notifications
SystemdService=mako.service
```

There is no `mako.service`. mako *ships* one in `share/systemd/user/`, but that directory
is only scanned for packages in the **system** `systemd.packages`, and mako here is a home
package. So the first `notify-send` asks the bus for the notification server, the bus asks
systemd for a unit that does not exist, and the notification is dropped with a D-Bus error
that nothing surfaces.

`home/chime/mako.nix` writes the unit itself, `Type = "dbus"` with
`BusName = org.freedesktop.Notifications`, wanted by `graphical-session.target`. That both
closes the activation gap and starts mako up front, which is what you want from a daemon
whose entire job is to already be listening.

One tuning note, measured: **`group-by = "app-name"` hides notifications.** Two unrelated
`notify-send` messages collapsed into a single bubble reading `(2) Critical`, and the first
message's text was simply not on screen. `group-by = "summary"` still collapses a repeated
notification — which is the point of grouping — and leaves two different ones as two.

## 7. Smaller things worth carrying forward

| Thing | Detail |
|---|---|
| **`noto-fonts-emoji` throws** | It is an alias now: `error: 'noto-fonts-emoji' has been renamed to/replaced by 'noto-fonts-color-emoji'`. Not a warning — the evaluation stops. |
| **Two Nerd Font families, and they are not interchangeable** | `CaskaydiaMono Nerd Font` draws icons at their natural width; `CaskaydiaMono Nerd Font Mono` forces every glyph into one cell. The first is right for a bar (the Mono patch clips wide symbols), the second for a terminal (a double-width glyph breaks the grid). Both are in the same package, along with `… Propo`. |
| **foot wants `[colors-dark]`** | `[colors]` still works and prints `deprecated: use [colors-dark] instead` **once per key** — twenty warning lines at the top of every terminal. |
| **foot's cursor colour is not in `[cursor]`** | `[cursor]` is style only. `[cursor] color = …` is rejected outright — *"not a valid option: color"* — printed into the terminal it failed to configure. The colours are `[colors-dark] cursor = <text> <cursor>`. |
| **`programs.foot.package` is not nullable** | Unlike hyprland's, so foot could not stay in `environment.systemPackages` once home-manager started configuring it — that would put two builds on `PATH`. It moved to `home/chime/foot.nix`; `useUserPackages` installs to `/etc/profiles/per-user/chime`, which is on the session `PATH`, so `$terminal = "foot"` resolves unchanged. |
| **`pkill -f` self-destructs, again** | `phase-3.md` §7 records it and it still caught us: `ssh host 'pkill -f "bin/walker"'` kills the ssh session running it, because the pattern is in its own command line. Exit code 255 and no output. Use `pkill -x`. |
| **`environment.sessionVariables` needs a reboot, not a rebuild** | It lands in `/etc/pam/environment`, read once at PAM session start. A `bento rebuild` will not put `GSK_RENDERER` into the running session's systemd user environment. `systemctl --user show-environment` says what the session actually has. |
| **Waybar module choice is a hardware statement** | No battery, no backlight, no audio device behind this guest. A `battery` module reporting `0%` for a battery that does not exist is worse than no battery module. |

## 8. Settled for later phases — do not re-litigate

- **`GSK_RENDERER=cairo` stays** while `softwareRendering` is on (§2). Anything GTK 4 in
  Phase 5 depends on it. Chromium is not GTK 4 and has its own flags.
- **swaybg, not hyprpaper** (§3). Do not "restore the planned tool" without re-testing the
  `AB4H` allocation; the crash is in hyprtoolkit, so anything else built on hyprtoolkit is
  suspect on this guest too.
- **Glyphs are codepoints, never pasted characters** (§1). `home/chime/theme/default.nix`
  has the `glyph` helper; add to `icons` rather than inlining a character anywhere.
- **The theme has three vocabularies and consumers use exactly one of them.** `palette` is
  Tokyo Night's own names, `hex`/`css` are *roles* (`background`, `accent`, `warn`), and
  `terminal` is the ANSI 16. Every config reads roles or `terminal`; a config that reached
  for `palette.blue7` would weld itself to Tokyo Night's naming and break the theme-switcher
  seam PLAN-v1 §4 step 3 asks for. **Phase 5's ghostty wants `theme.colors.terminal`,
  which is already the exact shape it needs.**
- **`$terminal` in `home/chime/hyprland.nix` is still the one line** that switches foot →
  ghostty. `home/chime/foot.nix` stays afterwards, themed, as the fallback that cannot be
  the reason a graphical test fails.
- **Super+B is still deliberately unbound** — it arrives with chromium in Phase 5.
- **The wallpaper is generated, not downloaded.** `python3 scripts/make-wallpaper.py`,
  pure standard library, deterministic, ~7 s. Change the palette and re-run it; do not
  hand-edit the PNG.
- **The mouse cursor is still Hyprland's default** (a teal droplet, visible in every
  screenshot). It is the last unthemed thing on the desktop and was left alone: it is not
  in Phase 4's scope and `home.pointerCursor` pulls in an X11/GTK icon-theme surface that
  deserves its own measurement.
