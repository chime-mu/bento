# What Phase 3 taught us

**Date:** 2026-08-30 · **Host:** Apple Silicon MacBook (M4), macOS 26.5.2 · **Guest:** NixOS
`26.11.20260828.83199d0`, Hyprland **0.56.2**, aquamarine **0.14.0**, mesa **26.2.1**,
kernel 6.18.47, `aarch64`
**Outcome:** ✅ Phase 3 complete — the VM boots straight into Hyprland, on llvmpipe, with a
clean compositor log.

Findings log for Phase 3: the Wayland desktop. Everything here was measured inside the
running VM. Where it contradicts `PLAN-v1.md`, the earlier learned files or upstream
documentation, that is called out.

## Acceptance — verified, including the two criteria that "need the screen"

| Criterion | Result | How |
|---|---|---|
| VM boots straight into Hyprland | ✅ autologin as `chime` 4 s after greetd starts, no password | `journalctl -u greetd -b`, `loginctl show-session` → `Type=wayland Class=user TTY=tty1`, and a screenshot of the actual scanout |
| A terminal opens with Super+Return | ✅ `foot` window, `class: foot`, 1900×1060 | Super+Return **pressed on the emulated keyboard from the host**, then `hyprctl clients` and a screenshot |
| `echo $XDG_SESSION_TYPE` prints `wayland` | ✅ `XDG_SESSION_TYPE=wayland` | *typed into that terminal* from the host and read back off the screen |
| `nix flake check` still green | ✅ exit 0 in 12 s, natively in the guest | — |

**Nothing here was left for a human to confirm.** That is the part of this phase worth
carrying forward, and §1 is how.

**Timings:**

| Operation | Time |
|---|---|
| `bento rebuild` — first switch, pulling the whole desktop closure from cache | 2 m 36 s |
| `bento rebuild` — later desktop edits | ~30 s |
| Guest reboot to a usable Hyprland | ~25 s |

---

## 1. An agent can see the screen, and press keys on it — no human needed

`HANDOFF.md` framed Phase 3 as the first phase whose acceptance needs a human at the
monitor. It does not. Two mechanisms, both already in the box:

**Seeing.** QEMU renders the guest's scanout into host memory whether or not a window is
displaying it, and the QMP `screendump` command writes it out as a PNG:

```json
{"execute":"screendump","arguments":{"filename":"/tmp/shot.png","format":"png"}}
```

This works under `--headless` with `-display none`. It is the *outermost* possible check —
not "does the compositor believe it drew something", but "what would a human looking at the
QEMU window see". Every screenshot in this phase was taken that way.

**Pressing.** The same socket takes `sendkey` through `human-monitor-command`, which drives
the emulated USB keyboard:

```json
{"execute":"human-monitor-command","arguments":{"command-line":"sendkey meta_l-ret"}}
```

That is the only way to test a *compositor keybinding* — `hyprctl dispatch exec foot` proves
the compositor can spawn a terminal, which is a different claim from "Super+Return is bound
and the key reaches the compositor". Typing a string, character by character, then tests the
next layer out again: that keyboard input reaches a *client*, which is how
`echo $XDG_SESSION_TYPE` was answered on screen rather than by reading `/proc/*/environ`.

Both are in `scripts/vm-screenshot.sh` (`--key`, `--type`), and `run-vm.sh` now opens the
QMP socket at `artifacts/qmp.sock`. Notes for whoever uses them next:

- Key **names** are QEMU's, not X11's: Super is `meta_l`, Return is `ret`, Space is `spc`.
  Shifted ASCII has to be spelled out — `$` is `shift-4`, `_` is `shift-minus`.
- Send characters with a small gap (50 ms here). Firing a string at full speed drops keys.
- QMP needs its `qmp_capabilities` handshake before it accepts any other command, and it
  interleaves asynchronous events with replies, so a client must skip messages with an
  `event` key rather than assuming the next line is its answer.

### `--headless` must keep the GPU, and that changes the PCI topology

`run-vm.sh --headless` used to pass `-display none` *and drop* `-device virtio-gpu-pci`.
With no GPU there is no `/dev/dri/card0`, and a compositor has nothing to bind — the mode
would have been useless for exactly the phase that needs it. The GPU is now always present
and only the `-display` differs.

That is a one-line change with a boot-breaking side effect, and it cost the first twenty
minutes of the phase: **adding a PCI device renumbers the slots**, the boot entry EDK2 had
recorded in `artifacts/edk2-aarch64-vars.fd` on earlier runs pointed at a device path that
no longer resolved, and the firmware dropped into the UEFI Shell instead of booting.

```
BdsDxe: loading Boot0002 "EFI Internal Shell" ...
Press ESC in 5 seconds to skip startup.nsh or any other key to continue.
Shell>
```

`./scripts/run-vm.sh --reset-vars` throws the variable store away and the firmware finds
`/EFI/BOOT/BOOTAA64.EFI` again (`learned/phase-1.md` §4). Worth recognising on sight: the
symptom of *any* change to the emulated hardware layout is a UEFI Shell prompt, not an
error message.

Since the GPU is now attached in both modes, the recorded entry stays valid across
`--headless` and windowed runs — which it did not when the two modes had different topology.

## 2. Both software-rendering environment variables in the plan are wrong

`PLAN-v1.md` §3 step 2 mandates `WLR_RENDERER_ALLOW_SOFTWARE=1` and
`LIBGL_ALWAYS_SOFTWARE=1`, inherited from try-omarchy's guest overlay
(`learned/phase-0.md` §3). Measured on this guest, one does nothing and the other actively
breaks the compositor. **Neither is set.**

### `WLR_RENDERER_ALLOW_SOFTWARE` is read by nothing

Hyprland has not been a wlroots compositor since 0.41 — it renders through **aquamarine**,
its own backend library. The variable does not appear anywhere in Hyprland's link closure:

```
$ grep -aoc "aquamarine" .Hyprland-wrapped     # sanity: the grep works
11
$ grep -aoc "WLR_" .Hyprland-wrapped
0
$ for lib in $(ldd .Hyprland-wrapped | ...); do grep -aq WLR_RENDERER_ALLOW_SOFTWARE ...
(nothing)
```

aquamarine's own knobs are all `AQ_*` — `AQ_DRM_DEVICES`, `AQ_NO_ATOMIC`, `AQ_NO_MODIFIERS`,
`AQ_FORCE_LINEAR_BLIT`, `AQ_MGPU_NO_EXPLICIT`, `AQ_NO_KMS_REQUIREMENT`. If a future phase
needs to force something about rendering, that is the namespace to look in.

This is `PLAN-v1.md` risk #3 ("Hyprland-in-VM env vars churn") landing exactly as predicted,
and it is worth noting *how* it landed: the plan had already corrected
`WLR_NO_HARDWARE_CURSORS` → `WLR_RENDERER_ALLOW_SOFTWARE` once, from try-omarchy's source.
The correction was right about the name and wrong about the premise — try-omarchy runs an
**Arch** guest with whatever compositor Omarchy ships, and a variable that is load-bearing
there can be inert here. **Copying a setting across distributions carries its assumptions
with it.**

### `LIBGL_ALWAYS_SOFTWARE=1` is an active regression — and it is silent

This is the important one. With it set, Hyprland starts, draws, and *looks* completely fine
— and fails to build its DRM renderer on every single commit:

```
ERR from aquamarine ]: [EGL] eglQueryDeviceStringEXT errored out with EGL_BAD_PARAMETER
ERR from aquamarine ]: CDRMRenderer(drm): Can't create renderer, no matching devices found
ERR from aquamarine ]: drm: initMgpu: no renderer
ERR from aquamarine ]: drm: Failed to update renderer state for Virtual-1 on applyCommit
```

Measured on the same machine, same configuration, changing only that one variable:

| `LIBGL_ALWAYS_SOFTWARE` | log after ~2 min | `ERR` lines | renderer failures |
|---|---|---|---|
| `=1` | **7.8 MB** | 42 528 | 8 504 |
| unset | **12 KB** | 5 | **0** |

The mechanism: `LIBGL_ALWAYS_SOFTWARE` makes mesa hand back a software EGL device that has
no DRM node behind it, so aquamarine's `eglQueryDeviceStringEXT(EGL_DRM_DEVICE_FILE_EXT)`
lookup finds nothing to match against `/dev/dri/card0` and gives up — then retries, forever.

Left unset, the fallback that was wanted happens by itself, and the log says so plainly:

```
drm: Starting backend for /dev/dri/card0, with driver virtio_gpu
CDRMRenderer(drm): Using device /dev/dri/card0
ERR: [EGL] eglInitialize errored out with EGL_NOT_INITIALIZED: DRI2: failed to create screen
Creating CDRMRenderer on gpu /dev/dri/renderD128
Renderer: llvmpipe (LLVM 21.1.8, 128 bits)
```

One failure on the primary node — correct, there is no VirGL for mesa to create a GL screen
with — then the **render node**, where mesa picks llvmpipe on its own. Software rendering was
never something the guest had to be told to do; it is where it lands when the GPU declines.

Of the 5 remaining `ERR` lines, 3 are aquamarine probing for a Wayland backend (there is no
compositor to nest inside, so it falls through to DRM) and 2 are that single expected
`DRI2: failed to create screen`. That is a clean start.

> **Generalised lesson, and the third time this repo has hit it** (`phase-0.md` §1,
> `phase-2.md` §2): *a setting that produces a working screen is not a setting that works.*
> The desktop looked identical in both configurations. The difference was only visible in a
> log nobody had a reason to open — and in an 8500× difference in how much of it there was.

### What remains of `bento.desktop.softwareRendering`

It sets **no environment variables at all**. It is now a statement about the hardware that
`home/chime/hyprland.nix` reads through home-manager's `osConfig` to switch off the effects
that cost a full-screen pass per frame — animations, blur, shadows — and to stop Hyprland
looking for a hardware cursor plane that does not exist. `hyprctl monitors` confirms the
last one: `hardwareCursorsInUse: false`, `directScanoutBlockedBy: software renders/cursors`.

`vulkan-swrast`, which the plan names as a guest package, **does not exist in nixpkgs** at
this revision. Nothing is missing: lavapipe ships inside mesa (`mesa.vulkanDrivers` contains
`swrast`, `mesa.galliumDrivers` contains `llvmpipe`), and `hardware.graphics.enable` — which
`programs.hyprland` turns on for us — installs it. No package substitution was needed, only
the deletion of one that no longer exists separately.

## 3. `programs.hyprland.enable` is most of `modules/desktop.nix`

The plan's step 1 lists greetd, pipewire, xdg-desktop-portal-hyprland and polkit as things
to configure. Three of the four are already implied. `programs.hyprland.enable` pulls in
`nixos/modules/programs/wayland/wayland-session.nix`, which sets `security.polkit.enable`,
`programs.dconf`, `programs.xwayland`, both portals (hyprland's own and the GTK one), and
`services.graphical-desktop.enable` — and *that* module defaults on:

- `hardware.graphics.enable`
- `fonts.enableDefaultPackages` ← which is why `foot` has a font to render with in Phase 3,
  before `modules/fonts.nix` exists
- `services.pipewire` with `alsa.enable` and `pulse.enable`
- `xdg.autostart`, `xdg.mime`, `xdg.icons`, `xdg.menus`

So the module states only what is genuinely missing: `security.rtkit.enable` (pipewire asks
for realtime priority and cannot get it without rtkit), greetd, and the packages. Restating
the rest would be four more places to keep in sync with nixpkgs.

**Read the module before configuring around it.** The alternative — write out everything the
plan lists — would have worked, and would have quietly pinned a handful of options against
future nixpkgs changes for no reason.

## 4. greetd: `initial_session` fires once per *boot*, not per daemon start

Autologin is `services.greetd.settings.initial_session`; the greeter that runs afterwards is
`default_session`. Measured behaviour, which surprised us mid-phase and cost a confusing
experiment:

| Event | Which session runs |
|---|---|
| First greetd start after boot | `initial_session` → `pam_unix(greetd:session): session opened for user chime` |
| `systemctl restart greetd` | `default_session` → *`session opened for user greeter`* |

So **`systemctl restart greetd` does not re-test autologin** — it drops you at the agreety
login prompt. Anything that needs to observe the autologin path has to reboot the guest,
which takes ~25 s here. (Restarting greetd also does not kill an already-running Hyprland;
the session survives its parent, and the stale compositor then holds DRM master.)

Two related module facts:

- `services.greetd.vt` **no longer exists** (`mkRemovedOptionModule`, "The VT is now fixed to
  VT1"). Every guide that sets it is out of date.
- `services.greetd.restart` defaults to `!(settings ? initial_session)` — false whenever
  autologin is configured, deliberately, because restarting greetd re-triggers autologin and
  a Hyprland that crashes at startup would relaunch forever. Keep it that way: the failure
  stays visible instead of becoming a loop.

`default_session` is `agreety --cmd <Hyprland>`, so quitting Hyprland (Super+Shift+Q) leaves
a usable text login on tty1 rather than a dead screen.

Both session commands point at **`${config.security.wrapperDir}/Hyprland`**, not
`${pkgs.hyprland}/bin/Hyprland` as most greetd examples show. The NixOS module installs
Hyprland through `security.wrappers` with `cap_sys_nice+ep` so it can give itself SCHED_RR;
launching the store path directly silently drops that.

## 5. home-manager now writes `hyprland.lua` by default, not `hyprland.conf`

`wayland.windowManager.hyprland.configType` was added with a stateVersion-dependent default:
`hyprlang` for `home.stateVersion` before 26.05, **`lua` from 26.05 onward**. Ours is 26.11,
so leaving it unset writes `$XDG_CONFIG_HOME/hypr/hyprland.lua` and the Nix `settings`
attrset maps onto `hl.<name>(...)` Lua calls — a genuinely different configuration language,
in which none of wiki.hypr.land's or Omarchy's examples can be pasted.

It is set explicitly to `"hyprlang"`. Phases 4 and 5 lean on those references, and being
explicit also pins it against the default moving again.

The other half of the same seam: `package = null` and `portalPackage = null`, because the
NixOS module installs the compositor. home-manager then writes only the config file and the
`hyprland-session.target`, and installs nothing — no second Hyprland in the user profile
racing the system one on `PATH`.

home-manager reloads a live session after a rebuild with `hyprctl instances -j | jq ...`,
calling **`jq` by bare name**, so `jq` has to be on `PATH` or that hook fails on every
rebuild made while the desktop is running. It is in `modules/desktop.nix`.

## 6. Two Hyprland config names from every VM guide are now errors

Both were caught the same way — Hyprland prints config errors *on screen*, in a red box over
the wallpaper, which the QMP screenshot picked up immediately:

| Old spelling | Status in 0.56.2 | Replacement |
|---|---|---|
| `bind = $mod, J, togglesplit,` | `Invalid dispatcher: togglesplit` | `bind = $mod, J, layoutmsg, togglesplit` — it is a message to the dwindle layout, not a dispatcher |
| `misc:vfr = true` | `config option <misc:vfr> does not exist` | gone; variable refresh moved to `debug:vfr` and is **on by default**, so set nothing |

`pseudo` *is* still a dispatcher, which is why only one of the two bind lines had to change —
the rename was per-dispatcher, not a wholesale move.

The live compositor is the authority, and it will answer over ssh:

```bash
export XDG_RUNTIME_DIR=/run/user/1000 \
       HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr | head -1)
hyprctl descriptions | jq -r '.[].name' | grep -i vfr    # every config option that exists
hyprctl getoption general:border_size                    # what actually took effect
hyprctl binds                                            # what actually got bound
```

That last one matters: a config error does **not** stop Hyprland loading the rest of the
file. Everything else applied while those two lines were broken, so "the desktop came up" is
not evidence the config was accepted.

## 7. Smaller things that cost time

| Gotcha | Detail |
|---|---|
| **`pkill -f Hyprland` killed the ssh session running it** | `-f` matches the whole command line, and the command line of the `bash -c '...'` doing the killing contains the pattern. It killed itself, mid-experiment, leaving the guest half-reconfigured. Match on `pgrep -x` and the process's real `comm` — which here is `.Hyprland-wrapp`, the wrapper, not `Hyprland`. |
| **`ssh $OPTS host` does not word-split under zsh** | The Bash tool's shell is zsh, where an unquoted variable expands as *one* argument: `Bad port ' 2222 -o StrictHostKeyChecking=no ...'`. Use `${=VAR}`, an array, or a small wrapper script. |
| **The QMP unix socket must be removed before QEMU restarts** | Otherwise QEMU exits with "Address already in use" after any hard kill. `run-vm.sh` unlinks it first. |
| **`nix eval --raw nixpkgs#mesa` prints a path that does not exist** | It is the *store path*, not a realised output — nothing had built or fetched it yet. `ls` on it fails in a way that looks like a broken package. |
| **The port 2222 forward accepts connections before sshd is up** | slirp binds the host port when QEMU starts, so `nc -z localhost 2222` succeeds seconds into the boot and then ssh fails with `kex_exchange_identification: Connection reset by peer`. Poll with a real `ssh true`, not a port check. |

## 8. Settled for later phases — do not re-litigate

- **No software-rendering environment variables.** §2. If a rendering problem appears, the
  namespace to look in is `AQ_*`, and the first thing to read is
  `$XDG_RUNTIME_DIR/hypr/<sig>/hyprland.log` — its size alone is diagnostic.
- **`configType = "hyprlang"`.** §5. Phase 4's waybar/walker/mako work and every Omarchy
  reference assume it.
- **The compositor comes from the NixOS module, the config from home-manager.** Keep
  `package = null` on the home-manager side.
- **`foot` stays** after Phase 5 makes ghostty the default terminal — it is the fallback that
  cannot be the reason a graphical test fails, and `$terminal` in `hyprland.nix` is the one
  line that switches between them.
- **The Hyprland logo is still on** (`misc:disable_hyprland_logo` unset). It is the only
  thing on an otherwise empty screen that distinguishes a running compositor from a hung
  boot. Phase 4 should turn it off in the same commit that lands hyprpaper and a wallpaper —
  not before.
- **Phase 4 does not need a human either.** `scripts/vm-screenshot.sh` sees the bar, the
  launcher and the notification; `--key`/`--type` open them. Its acceptance criterion
  ("screenshot of the desktop shows themed bar") is now directly executable.
