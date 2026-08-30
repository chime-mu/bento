# Handoff — v1 is done

Written 2026-08-30, at the end of the Phase 6 session. (Supersedes the Phase 5 → Phase 6
handoff; its findings now live in `learned/phase-6.md`.)

**Phases 0–6 are all complete, including the stretch goal.** `PLAN-v1.md` said Phase 6 was
allowed to fail. It did not: the guest renders on the M4's GPU through VirGL, and
`glxinfo -B` reports `virgl (ANGLE (Apple, Apple M4, OpenGL 4.1 Metal - 90.5))` with
`Accelerated: yes`.

There is no Phase 7. **The next session needs a decision from you about what v2 is**, not
an implementation task — see "Where to go next".

## Do this first — the one thing still outstanding

**Log Claude Code in.** It needs your credentials and no agent can do it for you. This is
carried over unchanged from the Phase 5 handoff; nothing since has been able to close it.

```bash
./scripts/run-vm.sh                # only if it is not already up
ssh -p 2222 chime@localhost
cd ~/bento && claude               # pick a theme, then "Select login method"
```

Verified up to that prompt and no further: Claude Code 2.1.245 starts, renders, and asks.
The token lands in `~/.claude` inside the guest — it survives every `bento rebuild` and it
does **not** survive the clean loop, because `build-image.sh` replaces the disk.

## State to be aware of

**The bento VM is running, windowed, with VirGL**, on the self-built QEMU. Check before
assuming: `pgrep -fl qemu-system-aarch64` — and note the binary path in the output tells
you which mode it is in (`~/.local/state/bento/qemu-gl/...` means GL).

**Host and VM are in sync**, both trees clean — confirm with `./scripts/vm-sync.sh status`
rather than trusting this file. `bento doctor` over ssh answers everything else in one
screen and is still the right first command of a session:

```bash
ssh -p 2222 chime@localhost 'cd ~/bento && bento doctor'
```

**`artifacts/bento.qcow2` is the live disk and there is no snapshot behind it.**
`build-image.sh` replaces it outright and `bento gc --all` deletes the generations you
could roll back to. Treat both as destructive; `./scripts/vm-sync.sh pull` before either.
A re-image also costs the Claude Code login.

**Phase 6 added a host dependency for the first time since Phase 0**, and it is the only
part of this repo that is not declarative:

| What | Where | Undo |
|---|---|---|
| GL QEMU 10.1.2 | `~/.local/state/bento/qemu-gl` (36 MB, outside the repo) | `rm -rf`, then `--no-gl` |
| ANGLE + epoxy + virglrenderer | Homebrew, from the `startergo/qemu-virgl` tap | `brew uninstall virglrenderer libepoxy-angle libangle && brew untap startergo/qemu-virgl` |

Nothing in it needed sudo, and Homebrew's own `qemu` was left untouched and still works.
`./scripts/build-qemu-gl.sh --check` reports the state; `./scripts/build-qemu-gl.sh`
rebuilds it in about four minutes. **A macOS or Homebrew update could break this build** —
that is the standing risk, and `run-vm.sh --no-gl` is the standing answer.

The linux-builder is **not** running. It is needed only to rebuild the *image*.

| What | How to start |
|---|---|
| bento VM | `./scripts/run-vm.sh` (VirGL, windowed) · `--no-gl` · `--headless` |
| `linux-builder` VM | `./scripts/start-linux-builder.sh` |

## The three things most likely to bite whoever is next

Full detail in `learned/phase-6.md`; these are the ones that cost real time.

1. **A screenshot that comes back all black is the camera, not the desktop** (§3). QMP
   `screendump` copies the pixman surface, and under VirGL the scanout is a GL texture, so
   it writes a valid 1920×1080 PNG of nothing and reports no error.
   `scripts/vm-screenshot.sh` already handles this — it takes the picture with `grim`
   inside the guest whenever the running QEMU has a GL device — but anything else that
   talks to QMP directly will be quietly lied to. Sanity-check any screenshot with
   `./scripts/screen-colors.py <png> --hist`; one line, and `#000000 100.0%` is the tell.

   Corollary worth keeping: **`--no-gl` is the mode to debug a boot failure in.** grim
   needs a running compositor and cannot photograph a UEFI `Shell>` prompt; `screendump`
   can.

2. **This GPU is faster but *narrower* than software rendering** (§5). ANGLE is a GL ES
   implementation, so the guest gets `Max GLES[23] profile version: 3.0` and
   `Max core profile version: 0.0` — **no desktop GL core profile at all**, where llvmpipe
   had one. That is why ghostty needs `LIBGL_ALWAYS_SOFTWARE=1` scoped to its own binary
   (`home/chime/ghostty.nix`). Any new application that fails to get a GL context is
   probably hitting the same wall, and the same wrapper is the fix — **scoped to that
   binary, never session-wide**, which `learned/phase-3.md` §2 measured at 8504 renderer
   failures.

3. **`bento.desktop.softwareRendering` cannot tell you whether there is a GPU** (§4). It is
   evaluated when the system is built; the GPU appears when the VM is launched, and one
   disk image serves both. Anything that must be correct in both modes has to be
   unconditional — which is why `GSK_RENDERER=cairo` is still set despite Phases 4 and 5
   both predicting Phase 6 would delete it. Do not re-gate it.

## Where to go next — this needs your decision, not an agent's

`PLAN-v1.md` is finished. Its own stated horizon was *"v1 runs as a QEMU virtual machine on
an Apple Silicon MacBook. **Bare-metal comes later.**"* The obvious candidates, with what
each would actually cost:

- **Bare metal.** The configuration was written for it throughout — `modules/` is
  host-agnostic, `hosts/bento-vm/` holds everything virtual, and `softwareRendering` exists
  precisely so a real machine can not set it. The work is a new `hosts/<machine>/`, real
  `hardware-configuration.nix`, disk partitioning, and the first bento that has a battery,
  a backlight and wifi — all three of which `learned/phase-4.md` §7 notes were deliberately
  left out of waybar because this guest has none.
- **The theme switcher.** `home/chime/theme/` was built as the seam for it
  (`learned/phase-4.md` §8) and nothing has been allowed to reach past `colors.hex` /
  `colors.terminal` since. This is the cheapest real feature in the list.
- **Persuade the desktop to resize.** try-omarchy gets dynamic resolution from a Cocoa
  patch that publishes the live window size through virtio-gpu EDID
  (`learned/phase-0.md` §3). We are on a fixed 1920×1080 because we did not take that
  patch. Now that we build QEMU ourselves, taking it is a much smaller step than it was.
- **Nothing.** v1 does what it set out to do, and the honest option is to use it for a
  while and let the next phase be whatever annoys you first.

If the next session is an implementation phase, the prompt shape that has worked six times
running is still the right one:

> Implement **&lt;phase&gt;** in this repo (`/Users/chime/Workspace/Bento`). Read
> `PLAN-v1.md` and every `learned/phase-*.md` in full before doing anything — those files
> record measured facts that contradict upstream documentation, and you will waste time or
> break things working from the official docs. Verify the acceptance criteria yourself;
> list anything only I can do as manual steps at the end. If a named package or option no
> longer exists, find the current equivalent and note the substitution. Finish by writing
> `learned/<phase>.md`, `./scripts/vm-sync.sh pull`, and committing.
