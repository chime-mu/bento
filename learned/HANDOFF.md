# Handoff — starting Phase 6 in a fresh session

Written 2026-08-30, at the end of the Phase 5 session. (Supersedes the Phase 4 → Phase 5
handoff; its findings now live in `learned/phase-5.md`.)

**Phases 0–5 are complete. v1 is built.** What remains is Phase 6, the stretch goal, which
`PLAN-v1.md` explicitly says *is allowed to fail*.

## Do this first — the one thing Phase 5 could not do

**Log Claude Code in.** It needs your credentials and no agent can do it for you.

```bash
./scripts/run-vm.sh --headless     # only if it is not already up
ssh -p 2222 chime@localhost
cd ~/bento && claude               # pick a theme, then "Select login method"
```

Verified up to that prompt and no further: Claude Code 2.1.245 starts, renders, and asks.
The token lands in `~/.claude` inside the guest — it survives every `bento rebuild` and it
does **not** survive the clean loop, because `build-image.sh` replaces the disk. Re-login
is part of the cost of a re-image.

Everything else in Phase 5's acceptance was executed and verified by the agent.

## Paste this into the new session

> Implement **Phase 6** of `PLAN-v1.md` in this repo (`/Users/chime/Workspace/Bento`).
>
> Read `PLAN-v1.md` and every `learned/phase-*.md` in full before doing anything — the
> learned files record measured facts that contradict upstream documentation, and you will
> waste time or break things working from the official docs.
>
> **Phase 6 is different from 1–5: it is mostly *host* work, and it is allowed to fail.**
> The goal is GPU acceleration, and Phase 0 settled that this needs *replacing* the host's
> QEMU, not configuring it. Read `learned/phase-0.md` §2 and §3 first — §3 is a reading of
> try-omarchy's build scripts and is the reference implementation for exactly this host and
> guest. Do not re-test whether Homebrew's QEMU can do VirGL; it cannot, and that is
> recorded with the four probes that established it.
>
> Building QEMU from source, and code-signing it for `com.apple.security.hypervisor`, will
> need my involvement — batch anything requiring sudo into one script for me to run, the
> way `scripts/setup-linux-builder.sh` did in Phase 0.
>
> **If it works**, `run-vm.sh --gl` should switch modes and the software-rendering
> concessions come off — see "what Phase 6 gets to delete" below. **If it does not**,
> document the findings in `learned/phase-6.md`, leave the VM on software rendering, and
> say so plainly. A failed Phase 6 that is well documented is the expected outcome, not a
> disappointment.
>
> Finish by writing `learned/phase-6.md`, `./scripts/vm-sync.sh pull`, and committing.

## State to be aware of

**The bento VM is running, windowed**, with a live Hyprland session a human may be looking
at. Check before assuming: `pgrep -fl qemu-system-aarch64`. Do not restart it just to get
`--headless` — the GPU is attached in both modes and `scripts/vm-screenshot.sh` works
either way.

**Host and VM are in sync**, both trees clean — confirm with `./scripts/vm-sync.sh status`
rather than trusting this file — a handoff that names a commit is stale the moment anyone
commits, which is why this one does not. The guest has been rebuilt about thirty times on
top of the Phase 1 image and was left in sync with `main`.

**`bento doctor` (new in Phase 5) answers all of this in one screen**, and it is the right
first command of the session:

```bash
ssh -p 2222 chime@localhost 'cd ~/bento && bento doctor'
```

It reads only — nothing it prints is computed or changed — and it says outright whether the
running system is the commit you are about to read, which is the question every other
answer depends on.

**`artifacts/bento.qcow2` is the live disk and there is no snapshot behind it.**
`build-image.sh` replaces it outright and `bento gc --all` deletes the generations you
could roll back to. Treat both as destructive; `./scripts/vm-sync.sh pull` before either.
**A re-image now also costs the Claude Code login.**

**Everything Phase 0 put under `/etc` is untouched.** Phases 1–5 needed no sudo on the
host. Phase 6 will be the first that does.

The linux-builder is **not** running. Phase 6 needs it only if it rebuilds the image.

| What | How to start | Needed for Phase 6? |
|---|---|---|
| bento VM | `./scripts/run-vm.sh` (windowed) or `--headless` | **yes** — already up |
| `linux-builder` VM | `./scripts/start-linux-builder.sh` | only to rebuild the *image* |

## What Phase 6 gets to delete, if it succeeds

Software rendering is not spread through the config — it hangs off one option, and these
are the places that read it. This list is the phase's own acceptance checklist in reverse:

| Where | What comes off |
|---|---|
| `hosts/bento-vm/default.nix` | `bento.desktop.softwareRendering = true` — the single switch |
| `modules/desktop.nix` | `GSK_RENDERER = "cairo"` (`learned/phase-4.md` §2) |
| `home/chime/hyprland.nix` | animations, blur, shadows and `no_hardware_cursors` all key off the option and come back on by themselves |
| `home/chime/wallpaper.nix` | swaybg could go back to hyprpaper — **but re-test the `AB4H` GBM allocation first** (`learned/phase-4.md` §3); the crash is a missing null check in hyprtoolkit, and real GL may or may not clear it |

`scripts/run-vm.sh` is where `--gl` belongs, next to the existing `--headless` and
`--reset-vars`.

**Beware the trap `learned/phase-3.md` §1 records:** adding or removing an emulated PCI
device renumbers the slots, the boot entry in `artifacts/edk2-aarch64-vars.fd` stops
resolving, and the firmware drops to a `Shell>` prompt instead of booting. Swapping
`virtio-gpu-pci` for `virtio-gpu-gl-pci` is exactly that kind of change.
`./scripts/run-vm.sh --reset-vars` is the fix, and a UEFI Shell prompt is the symptom to
recognise on sight.

## The Phase 5 findings most likely to bite Phase 6

Full detail in `learned/phase-5.md`.

1. **A daemon that indexes a Nix profile is wrong from the next rebuild onwards, and cannot
   notice** (§1). elephant scanned `XDG_DATA_DIRS` once at login, and the launcher then
   reported "Nothing matches" for software that was installed, on `PATH` and already
   running. A rebuild repoints the profile *symlink* at a new store path rather than
   touching the old directory, so neither a scan nor an inotify watch ever invalidates.
   `home/chime/walker.nix` fixes it with `X-Restart-Triggers`; anything new that indexes
   `PATH`, fonts or icons needs the same. Never trigger on `system.build.toplevel` — from
   inside home-manager that is an infinite recursion.

2. **`learned/phase-4.md` §8's "anything GTK 4 depends on `GSK_RENDERER=cairo`" is too
   broad** (§6). Ghostty is GTK 4 and draws identically with `GSK_RENDERER=gl`, because it
   renders its own terminal grid and hands GSK almost no widget chrome. The correct claim
   is "GSK's *widget* rendering is broken here". If Phase 6 lands real GL, walker is the
   application to re-test the variable against — it is the one that actually depends on it.

3. **Verify colours by sampling the scanout, not by looking at it** (§8). Phase 6's whole
   claim is about rendering, so this is the phase that most needs it:

   ```bash
   ./scripts/vm-screenshot.sh artifacts/shot.png
   ./scripts/screen-colors.py artifacts/shot.png --hist    # the 12 commonest colours
   ./scripts/screen-colors.py artifacts/shot.png 960,540   # one pixel
   ```

   It turns "does it look right" into a number checked against
   `home/chime/theme/colors.nix` — Phase 5 used it to establish that a ghostty window was
   96.9 % `#1a1b26` rather than merely dark. Pure standard library, because macOS has no
   PIL.

4. **`nix build --dry-run | tail` hides the verdict** (§9). "will be built" / "will be
   fetched" is the *first* line, before the path list. Grep for it.

5. **A findings log naming a package version is perishable.** `nodejs_20`, which the
   *previous* handoff recommended, had been deleted from nixpkgs by the time Phase 5 ran —
   and it `throw`s rather than warns. Re-run every probe.

6. **`writeShellApplication` treats shellcheck info-level findings as fatal**, and
   shellcheck's own output dies on non-ASCII in the script (`cannot encode character
   '\8212'` — an em-dash in a comment), truncating the diagnostics mid-sentence (§7). If a
   shell-script build fails with a garbled message, the real error list is longer than what
   you can see.

7. **`pkill -f` still kills the ssh session running it.** `phase-3.md` §7 said so, Phase 4
   did it again, and it is still true. Use `pkill -x`. Exit code 255 and no output.
