# What Phase 6 taught us

**Date:** 2026-08-30 · **Host:** Apple Silicon MacBook (M4), macOS 26.5.2 · **Guest:** NixOS
`26.11.20260828.83199d0`, Hyprland **0.56.2**, mesa **26.2.1**, `aarch64`
**Host QEMU:** **10.1.2** built from source · virglrenderer **1.2.0** · ANGLE
**2025.11.24** · libepoxy-angle **2025.03.08.1**
**Outcome:** ✅ Phase 6 complete — the guest renders on the M4's GPU.

Findings log for Phase 6: GPU acceleration. **PLAN-v1 says this phase is allowed to fail.
It did not.** Everything here was measured on this machine; where it contradicts
`PLAN-v1.md`, the earlier learned files or upstream documentation, that is called out.

The one line that summarises the phase, from the guest's own compositor log:

```
Renderer: virgl (ANGLE (Apple, Apple M4, OpenGL 4.1 Metal - 90.5))
```

Read right to left, that is the whole chain: Metal on the M4, ANGLE translating GL ES to
it, virglrenderer marshalling from the host QEMU, and mesa's virgl Gallium driver in the
guest.

## Acceptance — verified

| Criterion | Result | How |
|---|---|---|
| `glxinfo -B` reports virgl instead of llvmpipe | ✅ `virgl (ANGLE (Apple, Apple M4, OpenGL 4.1 Metal - 90.5))`, **`Accelerated: yes`** | in the guest |
| Hyprland animations visibly smooth | ✅ 80 animated workspace switches cost the compositor **26.16 CPU-seconds under llvmpipe and 0.03 under virgl** | §6 |
| *(beyond the criteria)* the desktop still works | ✅ waybar, walker, wallpaper, notifications, Super+Return, Super+B, launcher activation | grim + `screen-colors.py` |
| *(beyond the criteria)* the software path still works | ✅ `run-vm.sh --no-gl` boots and the launcher still draws | §4 |
| `nix flake check` still green | ✅ exit 0 in 13 s, natively in the guest | — |
| Compositor still healthy | ✅ `hyprland.log` **10 216 bytes, 5 `ERR`** — *fewer* bytes than the 12 107 software baseline, same error count | §9 |
| No failed units | ✅ system and user both empty | — |

**No sudo was needed anywhere in this phase**, which `PLAN-v1.md` §6 and the Phase 5
handoff both expected to be required. §1 explains why.

**One regression, found and fixed: ghostty.** It is the only thing the GPU made worse, and
it is worse in a way nobody would predict — see §5.

---

## 1. The host QEMU: three pieces, and why we built rather than poured

`learned/phase-0.md` §2 settled that Homebrew's QEMU cannot do VirGL, and it is still true
at 11.1.1 — re-confirmed in one command, not re-litigated. Getting GL means replacing the
binary. Three things have to come together and all three are load-bearing:

| Piece | Why |
|---|---|
| **ANGLE** | macOS has no EGL at all and its OpenGL stops at 4.1. ANGLE implements GL ES over Metal and supplies the EGL that virglrenderer needs. Homebrew core has no ANGLE. |
| **libepoxy-angle** | epoxy built against *that* ANGLE rather than the system GL, so QEMU and virglrenderer resolve the same symbols. |
| **the patch** | akihikodaki's macOS VirGL series, vendored as `scripts/patches/qemu-10.1-macos-virgl.patch`. |

The patch is **not optional and cannot be substituted by configure flags**, which is the
thing most worth knowing here:

> **Upstream QEMU's Cocoa UI contains no OpenGL code whatsoever** — measured, not assumed:
> `grep -ci 'egl\|opengl\|dpy_gl' ui/cocoa.m` returns **0** in v10.1.1, in v11.1.1 *and in
> master*. So `--enable-opengl --enable-virglrenderer` on a stock tree gets you a
> `virtio-gpu-gl-pci` device and a display backend that cannot give it a context.

What the patch does, in one sentence each: decouples `CONFIG_EGL` from `CONFIG_OPENGL`
(stock `meson.build` assumes anything with GL has EGL, which is false on macOS), adds
`OpenGL` to cocoa's framework list, and teaches virtio-gpu to borrow virglrenderer's
scanout texture.

### Why not just install the tap's prebuilt qemu-virgl

`startergo/qemu-virgl` ships a bottled `qemu-virgl` 10.1.2 with all of this already done —
the obvious move, and the formula is named differently from core `qemu` so it would not
even displace the working binary. It was rejected after reading what it would drag in:

```
Would install 61 dependencies for qemu-virgl:  … spice-protocol virglrenderer faac faad2
fdk-aac mpg123 lame musepack taglib srt srtp gstreamer spice-server …
Would upgrade 20 dependencies:  freetype fontconfig harfbuzz pango icu4c@78 librsvg …
```

`otool -L` on the bottle confirms it genuinely links `libspice-server.1.dylib`, and
spice-server pulls gstreamer and its codec zoo. Sixty-one new formulae and twenty upgrades
of *unrelated* packages — icu4c, harfbuzz, pango — is a large, hard-to-reverse change to
someone's machine in exchange for skipping one compile.

`--disable-spice` costs a build and nothing else: **every remaining dependency was already
installed for Homebrew's qemu.** Only the three GL formulas are taken from the tap, they
are bottled, and they total ~18 MiB whose only additional dependencies are `rapidjson` and
`spice-protocol` — both header-only.

`scripts/build-qemu-gl.sh` encodes all of it. One `aarch64-softmmu` target, ~4 minutes.

### QEMU signs itself — the code-signing step is a check, not a step

`PLAN-v1.md` §6 and `learned/phase-0.md` §2 both flag that a self-built QEMU must be
re-signed with `com.apple.security.hypervisor` or hvf will refuse it, and the Phase 5
handoff put code-signing on the list of things needing a human. **It needs neither a human
nor an action:** `make install` runs QEMU's own `scripts/entitlement.sh`, which ad-hoc
signs the binary with `accel/hvf/entitlements.plist`.

Better to know before you write the signing step, because re-signing afterwards *fails*:

```
/…/qemu-system-aarch64: replacing existing signature
/…/qemu-system-aarch64: resource fork, Finder information, or similar detritus not allowed
```

`entitlement.sh` also attaches `pc-bios/qemu.rsrc` as a resource fork for the app icon, and
`codesign --force` rejects a binary carrying one. The script now *verifies* the entitlement
and prints the manual command only if it is somehow missing.

### Homebrew now gates third-party taps behind `brew trust`

New since the earlier phases and it stops a tap dead:

```
Error: Refusing to load formula startergo/qemu-virgl/libangle from untrusted tap.
Run `brew trust --formula …` or `brew trust startergo/qemu-virgl` to trust it.
```

`PLAN-v1.md` §6 pre-authorises exactly this class of tap (it names knazarov and popey;
`startergo` is the maintained successor of both), so the trust was granted deliberately.
Undoing the whole phase's host footprint is two commands, and `build-qemu-gl.sh` prints
them in its own error path:

```bash
brew uninstall virglrenderer libepoxy-angle libangle
brew untap startergo/qemu-virgl
```

Also worth knowing: **`arm64_sequoia` bottles pour cleanly on macOS 26 (Tahoe)**. Homebrew
falls back to older macOS bottle tags on the same architecture, so a tap that stopped
building new bottles at macOS 15 is still usable.

## 2. Swapping the GPU device does *not* renumber the PCI slots

`learned/phase-3.md` §1 records that adding or removing an emulated PCI device renumbers
the slots, invalidates the boot entry in `artifacts/edk2-aarch64-vars.fd`, and drops the
firmware to a `Shell>` prompt. The Phase 5 handoff flags swapping `virtio-gpu-pci` for
`virtio-gpu-gl-pci` as "exactly that kind of change" and tells you to expect
`--reset-vars`.

**It is not, and you do not.** The first `--gl` boot went straight through to systemd-boot:

```
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x4,0x0)
```

The device is *replaced*, not added, so the slot count is unchanged and the recorded device
path still resolves. The trap is real but it is about the number and order of devices, not
their identity. `--reset-vars` remains the fix if a future change does add one.

## 3. `screendump` goes blind under GL — and it does not tell you

**This is the phase's most important finding**, because it silently breaks the mechanism
Phases 3, 4 and 5 used to verify every single graphical acceptance criterion.

`learned/phase-3.md` §1 established QMP `screendump` as "the outermost possible check". The
first screenshot taken under `--gl` was a valid 1920×1080 PNG that was **100 % `#000000`**,
on a desktop that was running perfectly.

The cause is three lines of `ui/ui-qmp-cmds.c`, and it is structural rather than a bug:

```c
surface = qemu_console_surface(con);
if (!surface) { error_setg(errp, "no surface"); return; }
image = pixman_image_ref(surface->image);
```

`screendump` copies **`surface->image`, the pixman `DisplaySurface`, and nothing else.**
There is no GL texture read-back path anywhere in it. With `virtio-gpu-gl` the guest's
scanout is a GL texture handed straight to Cocoa, and the pixman surface it reads is real,
allocated, and blank — so the `!surface` guard does not fire, no error is raised, and you
get a perfectly valid photograph of nothing.

> **The now-familiar lesson, in its sharpest form yet.** Phases 0–5 each recorded a version
> of *"a setting that produces a working screen is not a setting that works"*. This is the
> exact inverse: **a working screen that produces a blank photograph.** Every previous
> instance was caught because the picture looked right and the log did not. Here the log is
> clean, the desktop is correct, and only the *evidence* is wrong — which is the one thing
> none of the earlier heuristics would have caught.

**The fix is `grim`, inside the guest, over ssh.** It asks the compositor for its output
instead of reading QEMU's framebuffer, so it works in both modes. It was already installed
(`modules/desktop.nix` has had it since Phase 3). `scripts/vm-screenshot.sh` now chooses
the path by inspecting what GPU the running QEMU was actually given, so nothing has to
remember a flag; `--scanout` and `--guest` force it.

What is genuinely lost: the guest path is one layer further in. `screendump` answered *"what
would a human looking at the QEMU window see"* including the firmware, the boot messages and
a hung compositor. grim can only answer once a compositor is running and cannot photograph a
UEFI `Shell>` prompt. **`--no-gl` is therefore the mode to debug a boot failure in**, and
that is now a reason to keep the software path working beyond mere politeness.

## 4. A build-time option cannot describe a runtime GPU

`bento.desktop.softwareRendering` is evaluated when the system is built. Whether a GPU
exists is decided when `run-vm.sh` is invoked. **One disk image serves both**, and this is
the tension the whole configuration side of this phase turns on.

`learned/phase-4.md` §8 says `GSK_RENDERER=cairo` is "one of the lines Phase 6 deletes", and
the Phase 5 handoff repeats it. **It was not deleted, and it was moved out of the option
instead**, which is the opposite of what both predicted:

- gated on the build-time option, the variable is *wrong in whichever mode the system was
  not built for*, and being wrong here means walker maps a 1920×1080 layer surface and draws
  nothing into it (`learned/phase-4.md` §2) — a launcher nobody can see;
- `cairo` is the one value that is **correct in both**. It is the only renderer that works
  without a GPU, and with one it costs a rounding error, because GTK 4 widget chrome is
  nothing beside what the compositor is already drawing.

So `softwareRendering` now controls only the cosmetic effects that key off it — animations,
blur, shadows, `no_hardware_cursors` — and it is `false`. `--no-gl` remains a *working*
fallback rather than a broken one: merely sluggish, which is exactly what the option has
always meant. Verified rather than assumed, by booting it: walker draws, and the screenshot
histogram is **17.8 % `#1a1b26`, identical to the GL run's**.

**The Phase 5 open question, answered.** `learned/phase-5.md` §10 asks that walker be
re-tested against `GSK_RENDERER` if GL ever lands. It was, with a systemd drop-in, and the
process's own `/proc/<pid>/environ` confirms which renderer it had: under VirGL walker draws
correctly with **`GSK_RENDERER=gl`**. GSK's widget rendering is fixed by a real GPU. The
variable stays anyway, for the fallback — but the claim is now measured in both directions
rather than inherited.

## 5. The one regression: ghostty needs desktop GL, and this GPU has none

Ghostty drew fine on llvmpipe through Phase 5 (96.9 % `#1a1b26`). Under VirGL it does not
start at all — a full-screen **"Oh, no. Unable to acquire an OpenGL context for
rendering."** The default terminal, on Super+Return.

The reason is in `glxinfo -B`, and it is a property of the whole stack rather than of
ghostty:

```
Max core profile version:   0.0     ← there is no desktop GL core profile at all
Max compat profile version: 2.1
Max GLES[23] profile version: 3.0
```

ANGLE is a GL **ES** implementation. virglrenderer running on it can only offer the guest
GLES 3.0 and a compat GL 2.1, so mesa's virgl driver advertises no core profile whatsoever.
llvmpipe, being a complete software GL, offered one — which is why this breaks *because of*
the upgrade.

**GL acceleration here is faster but narrower than software rendering.** That is the
generalisable point, and it is not the trade-off one expects.

Ghostty insists on desktop GL and says so in its own startup log, overriding the
environment — so `GDK_DEBUG=gl-gles` accomplishes nothing:

```
warning(gtk_ghostty_application): setting GDK_DEBUG=
warning(gtk_ghostty_application): setting GDK_DISABLE=gles-api,vulkan
```

The fix gives **that one process** a software GL stack while everything else keeps the GPU:
`home/chime/ghostty.nix` wraps the binary with `LIBGL_ALWAYS_SOFTWARE=1`.

That is the variable `learned/phase-3.md` §2 forbids, and **the prohibition is intact**. It
was always a statement about the *compositor*: given it, aquamarine gets an EGL device with
no DRM node behind it, fails to build a renderer on every commit, and produces 8504 failures
and a 7.8 MB log. A client that only wants a GL context for its own surface has no such
problem. The variable is not wrong; setting it session-wide is. **Scoping is the entire
point**, which is why it lives on the binary and not in `environment.sessionVariables`.

Two implementation notes:

- **`symlinkJoin` + `wrapProgram`, never `overrideAttrs`.** Overriding the derivation would
  rebuild ghostty from source inside the VM, which PLAN-v1 risk #2 exists to prevent. A
  symlinkJoin is a trivial derivation over the already-cached build.
- The desktop entry ships **`Exec=ghostty` by bare name**, so the launcher and `$terminal`
  in `home/chime/hyprland.nix` both resolve to the wrapper through `PATH` without either of
  them being told about it. Verified through both paths: Super+Return gives
  `class=com.mitchellh.ghostty` at 96.9 % `#1a1b26`, and elephant's journal reports
  `activated=com.mitchellh.ghostty.desktop`.

Chromium is unaffected — it already runs with `--disable-gpu` (`learned/phase-5.md` §6), so
it was never asking for a GL context in the first place.

## 6. glmark2 says software rendering is 20× faster. Do not believe it.

The honest numbers, same benchmark, same guest, same everything but the QEMU:

| `glmark2-es2-wayland --off-screen` | Score | build | texture | shading |
|---|---|---|---|---|
| llvmpipe (`--no-gl`) | **1418** | 1148 fps | 2391 fps | 718 fps |
| virgl (`--gl`) | **72** | 73 fps | 73 fps | 74 fps |

Taken at face value this says Phase 6 made the machine twenty times slower, and it would be
easy to publish that and be wrong. Two things give it away: virgl is pinned at 73–74 fps
across three completely different workloads — the signature of a **per-frame
synchronisation limit**, not of a rendering limit — while llvmpipe runs unthrottled because
an off-screen 800×600 buffer never leaves the guest's RAM and four fast ARM cores fill it
very quickly.

The compositor's actual workload is neither of those: it is full-screen 1920×1080
composition with blur and shadows. Measuring *that* — 80 animated workspace switches, timing
Hyprland's own CPU consumption out of `/proc/<pid>/stat`:

| | wall clock | Hyprland CPU |
|---|---|---|
| llvmpipe | 7205 ms | **26.16 s** |
| virgl | 381 ms | **0.03 s** |

19× faster in wall clock and **~870× less CPU**. Under llvmpipe the compositor saturates
roughly three and a half cores and cannot service its own IPC socket promptly; under virgl
it is essentially idle, because the drawing is happening on the M4's GPU.

> **Generalised lesson, and this repo's fourth variation on it.** `learned/phase-0.md` §1
> warned that a passing test which exercises the wrong mechanism is worse than no test. This
> is the benchmark version: **a synthetic benchmark measuring the wrong workload is worse
> than no benchmark**, because it produces a confident number pointing the wrong way. The
> question was never "how many triangles per second" — it was "what does drawing cost this
> machine", and that question has a direct answer in `/proc`.

## 7. What GL fixed for free

Three things that Phases 3–5 recorded as permanent limitations turn out to have been
symptoms of the missing GPU:

- **hyprpaper's `AB4H` crash is gone** (`learned/phase-4.md` §3). Re-tested as the handoff
  asked. hyprpaper 0.8.4 asks aquamarine's GBM allocator for `ABGR16161616F`; virtio-gpu had
  no such format, `gbm_bo_create` returned null and hyprtoolkit dereferenced it within a
  second. With `virtio-gpu-gl` the format exists: hyprpaper runs for as long as you leave it
  and the only GBM output is `WARN: GBM: Using modifier-less allocation`. The diagnosis was
  right all along.
  **swaybg stays anyway** — hyprpaper works in only *one* of the two modes this image runs
  in, and swaybg is correct in both. `home/chime/wallpaper.nix` records the result so nobody
  runs the experiment a third time.
- **hyprtoolkit windows draw**, which is the same fix from the other side — and the first
  thing it did was put Hyprland's "updated to 0.56.2!" dialog in the middle of the first
  screenshot of the phase. It had been failing invisibly since Phase 3.
  `ecosystem:no_update_news` and `no_donation_nag` are now off, for the same reason
  hyprlock's `fade_on_empty` and ghostty's `resize-overlay` are.
- **Hardware cursors work.** `hyprctl monitors -j` reports `hardwareCursorsInUse: true`,
  where `learned/phase-3.md` §2 recorded `false`.

## 8. The compositor log is *smaller*, and the five errors are a different five

`hyprland.log` is **10 216 bytes with 5 `ERR`**, against the 12 107 bytes with 5 `ERR` that
was byte-identical across Phases 3, 4 and 5. Same count, different pair:

| Phase 3–5 (llvmpipe) | Phase 6 (virgl) |
|---|---|
| 3 × aquamarine probing for a Wayland backend | *unchanged* |
| 2 × `[EGL] eglInitialize … DRI2: failed to create screen` | 2 × `eglCreateContext … EGL_BAD_MATCH` / `failed with GLES 3.2, retrying GLES 3.0` |

The old pair was "there is no GL on the primary node, fall back to the render node". The new
pair is "this GPU does not do GLES 3.2, fall back to 3.0" — which is the same
`Max GLES[23] profile version: 3.0` cap that breaks ghostty in §5, showing up in the
compositor as a one-line retry it handles correctly. Both are expected; neither repeats.

## 9. Smaller things that cost time

| Thing | Detail |
|---|---|
| **macOS `ps` truncates without `-ww`** | `ps -Ao command=` cuts each line at the terminal width. `-device virtio-gpu-gl-pci` sits ~250 characters into run-vm.sh's command line, so a GPU-mode detection built on it silently always answers "no". |
| **`\| grep -q` under `set -o pipefail` reports failure on *success*** | grep exits at the first match, `ps` dies of SIGPIPE, and pipefail returns *ps's* status. **Finding what you were looking for makes the test say no.** Cost twenty minutes because the symptom — a black screenshot — was indistinguishable from the bug the check exists to prevent. Use a bash `[[ $var == *pattern* ]]` and no pipe. |
| **`pgrep -x walker` finds nothing while walker is running** | Its `comm` is `.walker-wrapped`: nixpkgs wrapper scripts rename the process, and `comm` is capped at 15 characters. `learned/phase-3.md` §7 records the same thing for `.Hyprland-wrapp`. `ps -eo pid,args` and a bracket pattern is the reliable form. |
| **A stale D-Bus name looks like a renderer failure** | An orphaned walker held `dev.benz.walker`, and the service failing to start reported `Unable to acquire bus name` — five restarts and a `start-limit-hit`, with nothing about graphics in it. Check for an orphan before believing an error about the thing you were testing. |
| **`nix build --dry-run` on the *host* needs the Nix profile sourced** | Unchanged from `learned/phase-1.md` §8 and still the first thing every fresh Bash invocation hits. |
| **A backgrounded process started over ssh does not reliably outlive the session** | Even under `setsid`. Two experiments in this phase died between being started and being measured. `systemd-run --user` or a drop-in is the honest way to hold a process up for a test. |

## 10. Settled for later phases — do not re-litigate

- **`GSK_RENDERER=cairo` is unconditional and stays** (§4). It is not gated on
  `softwareRendering` and must not be re-gated: the option is build-time, the GPU is
  runtime, and one image serves both. Deleting it breaks the launcher in `--no-gl`.
- **Ghostty keeps its `LIBGL_ALWAYS_SOFTWARE` wrapper** (§5) until ghostty gains a GLES
  path or the guest gains a desktop-GL one. It is scoped to one binary on purpose; do not
  "simplify" it into `environment.sessionVariables`, which is the configuration
  `learned/phase-3.md` §2 measured at 8504 renderer failures.
- **`screendump` is not a valid check under `--gl`** (§3). `scripts/vm-screenshot.sh`
  picks the right path by itself; if a screenshot ever comes back uniformly black, suspect
  the capture before the desktop. `./scripts/screen-colors.py <png> --hist` answers it in
  one line.
- **`--no-gl` is a supported mode, not a legacy path.** It is the only way to photograph
  the firmware or a boot failure (§3), and it is the fallback if the GL build breaks after
  a nixpkgs or macOS update. Changes to the desktop should not assume a GPU.
- **swaybg, still — even though hyprpaper now works** (§7).
- **Do not benchmark this machine with glmark2** (§6). Measure the compositor's CPU out of
  `/proc/<pid>/stat` against a known workload instead.
- **The GL QEMU lives outside the repo**, at `~/.local/state/bento/qemu-gl`, beside Phase
  0's builder keys. `artifacts/` is gitignored and the binary is 36 MB. Rebuild it with
  `./scripts/build-qemu-gl.sh`; check it with `--check`.
- **`bento.desktop.softwareRendering = false` is a statement of intent, not a detected
  fact** — it says how this host is *meant* to be run. A bare-metal bento would set it the
  same way for a completely different reason.
