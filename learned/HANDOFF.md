# Handoff — starting Phase 3 in a fresh session

Written 2026-08-30, at the end of the Phase 2 session. (Supersedes the Phase 1 → Phase 2
handoff; the findings it carried now live in `learned/phase-1.md` and `learned/phase-2.md`.)

## Paste this into the new session

> Implement **Phase 3** of `PLAN-v1.md` in this repo (`/Users/chime/Workspace/Bento`).
>
> Read `PLAN-v1.md` and every `learned/phase-*.md` in full before doing anything — the
> learned files record measured facts that contradict upstream documentation, and you will
> waste time or break things working from the official docs.
>
> The decisions table in the plan is fixed; do not re-litigate it. If a named package or
> option doesn't exist in current nixpkgs, find the current equivalent and note the
> substitution in your report and in `learned/phase-3.md`.
>
> Phase 3 runs *inside* the VM via the Phase 2 loop. Start with:
>   ./scripts/run-vm.sh --headless   # fine for building; see below for the screen
>   ./scripts/vm-sync.sh push        # get this repo's HEAD into the VM
>   ssh -p 2222 chime@localhost      # then: cd ~/bento, edit, `bento rebuild`
> You do **not** need the linux builder or a new image.
>
> Phase 3 is the first phase whose acceptance needs the VM's *screen* — "boots straight
> into Hyprland", "Super+Return opens a terminal". Do as much as you can headlessly and
> over SSH (`systemctl status greetd`, `loginctl show-session`, `echo $XDG_SESSION_TYPE`
> in the graphical session), then tell me exactly what to look for when I run
> `./scripts/run-vm.sh` without `--headless` myself.
>
> Verify what you can yourself. Anything you cannot (needs the VM's screen, or my
> credentials) — list it for me as explicit manual steps at the end.
> Finish by writing `learned/phase-3.md`, `./scripts/vm-sync.sh pull`, and committing.

## State to be aware of

**Nothing is running.** The bento VM was powered off cleanly (`sudo systemctl poweroff`)
at the end of the Phase 2 session; the linux-builder was never started at all, and Phase 3
does not need it.

| What | How to start | Needed for Phase 3? |
|---|---|---|
| bento VM | `./scripts/run-vm.sh --headless` | **yes** — Phase 3 happens inside it |
| `linux-builder` VM | `./scripts/start-linux-builder.sh` | no — only to rebuild the *image* |

**`artifacts/bento.qcow2` is the live disk, and it has moved on.** It boots to a guest that
has been rebuilt nine times on top of the Phase 1 image and now runs flake revision
`a5ba1d4` — the same commit as `main`, with `~/bento` inside it clean and in sync. There is
no snapshot behind it: `build-image.sh` replaces it outright, and `bento gc --all` inside
the guest deletes the older generations you could roll back to. Treat both as destructive.
(3.46 GiB used of a 60 G qcow2, ~54 G free inside.)

**The VM already has `~/bento`** as a real git repo with no `origin`, and this repo has it
as a remote named `vm`. `./scripts/vm-sync.sh status` shows whether they agree. If a push
ever fails with *"Too many authentication failures"*, the remote URL lost its port and is
hitting the Mac's own sshd — `./scripts/vm-sync.sh init` rewrites it.

**Everything Phase 0 put under `/etc` is untouched.** Phases 1 and 2 needed no sudo on the
host at all.

## The Phase 2 findings most likely to bite Phase 3

Full detail in `learned/phase-2.md`; these three have direct consequences, and Phase 3 is
the phase that adds the most *new files* so far — which is exactly what §3 is about.

1. **A rebuild sees edits to tracked files, but not new untracked ones.** A dirty tracked
   file works fine (`warning: Git tree is dirty`, then it uses your edits). A *new* file
   that nothing imports yet — a wallpaper, a themed config fragment — is invisible with **no
   error at all**, and the symptom is "my change did nothing". `bento rebuild` stages
   untracked files with `git add -N` before rebuilding for exactly this reason, but if you
   call `nixos-rebuild` directly you are on your own.

2. **Iterate with `bento rebuild`, and expect seconds.** 1.3 s for a no-op, 6.4 s to add a
   cached package. If something takes minutes, it is compiling from source — stop and
   check, because `PLAN-v1.md` risk #2 says never to build Chromium or Ghostty from source
   in the VM. Substitute and report instead.

3. **Run `nix flake check` inside the guest**, where it is a native `aarch64-linux`
   evaluation needing no builder. It omits `aarch64-darwin`; only the Mac can cover that,
   and only with the builder up.

## What Phase 3 is walking into

- Graphics are **software rendering, settled in Phase 0** — the host QEMU has no OpenGL
  compiled in at all. `learned/phase-0.md` §2 and §3 have the measured probes and
  try-omarchy's exact guest env vars. Use `WLR_RENDERER_ALLOW_SOFTWARE`, **not** the older
  `WLR_NO_HARDWARE_CURSORS` that early drafts of the plan guessed at.
- `run-vm.sh --headless` gives no window. Phase 3's acceptance needs the **Cocoa window**,
  so run `./scripts/run-vm.sh` without `--headless` — and note that only a human at the
  screen can confirm "boots straight into Hyprland".
- `hosts/bento-vm/hardware.nix` already passes `console=tty0` alongside the serial console
  specifically so the QEMU graphical window stays usable (`learned/phase-1.md` §3). Don't
  remove it.
