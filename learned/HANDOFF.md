# Handoff — starting Phase 4 in a fresh session

Written 2026-08-30, at the end of the Phase 3 session. (Supersedes the Phase 2 → Phase 3
handoff; its findings now live in `learned/phase-3.md`.)

## Paste this into the new session

> Implement **Phase 4** of `PLAN-v1.md` in this repo (`/Users/chime/Workspace/Bento`).
>
> Read `PLAN-v1.md` and every `learned/phase-*.md` in full before doing anything — the
> learned files record measured facts that contradict upstream documentation, and you will
> waste time or break things working from the official docs.
>
> The decisions table in the plan is fixed; do not re-litigate it. If a named package or
> option doesn't exist in current nixpkgs, find the current equivalent and note the
> substitution in your report and in `learned/phase-4.md`.
>
> Phase 4 runs *inside* the VM via the Phase 2 loop. Start with:
>   ./scripts/run-vm.sh --headless   # the GPU is attached even headless; this is enough
>   ./scripts/vm-sync.sh push        # get this repo's HEAD into the VM
>   ssh -p 2222 chime@localhost      # then: cd ~/bento, edit, `bento rebuild`
> You do **not** need the linux builder or a new image.
>
> **You can verify Phase 4's acceptance yourself — do not hand it to me.**
> `./scripts/vm-screenshot.sh` photographs the guest's actual screen over QMP, and
> `--key` / `--type` press keys on its emulated keyboard, all under `--headless`. That is
> how Phase 3 verified "boots into Hyprland" and "Super+Return opens a terminal" with
> nobody at the monitor. `learned/phase-3.md` §1 has the details and the gotchas.
>
> Anything you genuinely cannot verify (needs my credentials) — list it for me as explicit
> manual steps at the end. Finish by writing `learned/phase-4.md`, `./scripts/vm-sync.sh
> pull`, and committing.

## State to be aware of

**Nothing is running.** The bento VM was powered off cleanly at the end of the Phase 3
session; the linux-builder was never started, and Phase 4 does not need it.

| What | How to start | Needed for Phase 4? |
|---|---|---|
| bento VM | `./scripts/run-vm.sh --headless` | **yes** — Phase 4 happens inside it |
| `linux-builder` VM | `./scripts/start-linux-builder.sh` | no — only to rebuild the *image* |

**Host and VM are in sync at `bc7ba6d`**, both trees clean, and the running system is
stamped with that revision (`nixos-version --configuration-revision`). The guest is at
generation 14, rebuilt fourteen times on top of the Phase 1 image.

**`artifacts/bento.qcow2` is the live disk and there is no snapshot behind it.**
`build-image.sh` replaces it outright and `bento gc --all` deletes the generations you could
roll back to. Treat both as destructive; `./scripts/vm-sync.sh pull` before either.

**Everything Phase 0 put under `/etc` is untouched.** Phases 1–3 needed no sudo on the host.

## The Phase 3 findings most likely to bite Phase 4

Full detail in `learned/phase-3.md`. Phase 4 adds waybar, walker, mako, hyprlock/hypridle,
hyprpaper and a wallpaper — a lot of new files and a lot of new config dialects.

1. **You do not need a human to see the screen.** `./scripts/vm-screenshot.sh` (QMP
   `screendump`) and its `--key` / `--type` flags. Phase 4's acceptance — themed bar,
   launcher on Super+Space, a themed notification — is directly executable:
   `./scripts/vm-screenshot.sh --key meta_l-spc` opens the launcher and photographs it.

2. **A wallpaper is a new *untracked* file, and a flake cannot see untracked files** —
   silently, with no error (`learned/phase-2.md` §3). `bento rebuild` runs `git add -N`
   first for exactly this. If a themed asset "does nothing", check `git status` before
   anything else.

3. **Set no software-rendering environment variables, and be suspicious of any guide that
   tells you to.** Both variables PLAN-v1 §3 named turned out to be wrong here — one inert,
   one causing 8504 renderer failures behind a desktop that looked perfectly fine
   (`phase-3.md` §2). If Phase 4's tools misbehave under llvmpipe, read
   `$XDG_RUNTIME_DIR/hypr/<sig>/hyprland.log` — a healthy one is ~12 KB with 5 `ERR` lines.

4. **The Hyprland config is hyprlang, pinned explicitly** (`configType = "hyprlang"`), because
   home-manager's default at our stateVersion is now `lua`. Keep it, and keep
   `package = null` — the compositor comes from the NixOS module, the config from
   home-manager (`phase-3.md` §5).

5. **Config option and dispatcher names have moved.** `misc:vfr` and the `togglesplit`
   dispatcher are both errors in 0.56.2. Ask the live compositor rather than the wiki:
   `hyprctl descriptions | jq -r '.[].name'`, `hyprctl getoption <name>`, `hyprctl binds`.
   A config error does not stop the rest of the file loading, so "it came up" proves nothing.

6. **`systemctl restart greetd` does not re-test autologin** — `initial_session` fires once
   per boot, and a restart lands on the agreety greeter instead. Reboot the guest (~25 s).

## What Phase 4 is walking into

- **Turn off the Hyprland logo in the same commit that lands the wallpaper**, not before
  (`misc:disable_hyprland_logo`, currently unset on purpose — it is the only sign of life on
  an empty desktop).
- **`$terminal` in `home/chime/hyprland.nix` is the single line** that switches foot → ghostty
  in Phase 5. Super+Space is deliberately unbound until walker exists; Super+B until
  chromium does.
- **Fonts are the *default* set right now**, from `fonts.enableDefaultPackages`, which
  `programs.hyprland` turns on transitively. `modules/fonts.nix` is Phase 4's job, and
  `nerd-fonts.caskaydia-mono` needs checking against the current nixpkgs namespace.
- **Effects are off under `bento.desktop.softwareRendering`** — animations, blur, shadows —
  via `osConfig` in the home config. Theme what is left; do not turn them back on to make a
  screenshot look better.
- **Walker on aarch64 is a known risk** (PLAN-v1 risk #5); falling back to `fuzzel` is
  pre-authorized. Check it is *cached* before building — a source build in the VM is the
  thing PLAN-v1 risk #2 says to never do.
