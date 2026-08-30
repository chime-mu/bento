# Handoff — starting Phase 5 in a fresh session

Written 2026-08-30, at the end of the Phase 4 session. (Supersedes the Phase 3 → Phase 4
handoff; its findings now live in `learned/phase-4.md`.)

## Paste this into the new session

> Implement **Phase 5** of `PLAN-v1.md` in this repo (`/Users/chime/Workspace/Bento`).
>
> Read `PLAN-v1.md` and every `learned/phase-*.md` in full before doing anything — the
> learned files record measured facts that contradict upstream documentation, and you will
> waste time or break things working from the official docs.
>
> The decisions table in the plan is fixed; do not re-litigate it. If a named package or
> option doesn't exist in current nixpkgs, find the current equivalent and note the
> substitution in your report and in `learned/phase-5.md`.
>
> Phase 5 runs *inside* the VM via the Phase 2 loop. The VM is probably already running —
> check with `pgrep -fl qemu-system-aarch64` before starting a second one:
>   ./scripts/run-vm.sh --headless   # only if it is not up; the GPU is attached either way
>   ./scripts/vm-sync.sh status      # who is ahead of whom
>   ./scripts/vm-sync.sh push        # get this repo's HEAD into the VM
>   ssh -p 2222 chime@localhost      # then: cd ~/bento, edit, `bento rebuild`
> You do **not** need the linux builder or a new image.
>
> **Verify as much of Phase 5's acceptance as you can yourself — do not hand it to me.**
> `./scripts/vm-screenshot.sh` photographs the guest's actual screen over QMP, and
> `--key` / `--type` press keys on its emulated keyboard, all under `--headless`. Phase 4
> used it to open the launcher, type an application name into it, watch the app start, and
> type a password into the lock screen. `learned/phase-3.md` §1 has the mechanics.
>
> The one thing you genuinely cannot do is log Claude Code in — that needs my credentials.
> List that, and anything else like it, as explicit manual steps at the end. Finish by
> writing `learned/phase-5.md`, `./scripts/vm-sync.sh pull`, and committing.

## State to be aware of

**The bento VM is running, windowed**, with a live Hyprland session — bar, wallpaper,
launcher, the lot — that a human may be looking at. It was left up deliberately. Check
before assuming: `pgrep -fl qemu-system-aarch64`.

Two consequences:

- **Do not restart it just to get `--headless`.** There is no difference that matters: the
  GPU is attached in both modes and `scripts/vm-screenshot.sh` works either way. The window
  is a *bonus* — a human can watch what you are building.
- **A `bento rebuild` reloads that live session** (home-manager's Hyprland hook runs
  `hyprctl reload`, and it restarts the changed user services), which is what you want, but
  a broken config is visible to whoever is watching. Nothing is destroyed by it; greetd is
  not restarted.

**But note one thing a rebuild does *not* do.** `environment.sessionVariables` lands in
`/etc/pam/environment`, which is read once when the PAM session opens. Anything added there
— Phase 5 will add Chromium's Wayland hints if they are not already right — does not reach
the running session until the guest **reboots** (~25 s). `systemctl --user show-environment`
tells you what the session actually has, and `journalctl -u greetd -b` confirms the
autologin fired.

The linux-builder is **not** running and Phase 5 does not need it.

| What | How to start | Needed for Phase 5? |
|---|---|---|
| bento VM | `./scripts/run-vm.sh` (windowed) or `--headless` | **yes** — already up |
| `linux-builder` VM | `./scripts/start-linux-builder.sh` | no — only to rebuild the *image* |

**Host and VM are in sync**, both trees clean — confirm with `./scripts/vm-sync.sh status`
rather than trusting this file. The guest has been rebuilt twenty-five times on top of the
Phase 1 image, and `nixos-version --configuration-revision` reports the commit it was built
from. That stamp trails HEAD by any docs-only commits made after the last rebuild, which is
correct and not worth a rebuild to fix.

**`artifacts/bento.qcow2` is the live disk and there is no snapshot behind it.**
`build-image.sh` replaces it outright and `bento gc --all` deletes the generations you could
roll back to. Treat both as destructive; `./scripts/vm-sync.sh pull` before either.

**Everything Phase 0 put under `/etc` is untouched.** Phases 1–4 needed no sudo on the host.

## The Phase 4 findings most likely to bite Phase 5

Full detail in `learned/phase-4.md`. Phase 5 adds ghostty, chromium, neovim and claude-code
— three of them large, two of them GPU-adjacent.

1. **`GSK_RENDERER=cairo` is set for the whole session, and it has to stay.** GTK 4 has no
   working renderer on this guest: radv claims virtio-gpu and fails, then GSK's GL renderer
   fails too, and the result is a window that maps at the right size and draws *nothing*
   (`phase-4.md` §2). If a Phase 5 app appears invisible, that is the shape of the bug —
   check its toolkit before you check your config.

2. **Chromium and ghostty are the two packages most likely to want a source build.**
   PLAN-v1 risk #2 forbids that in the VM. Check *before* installing, with the probe Phase 4
   used on every package:
   `nix build --dry-run nixpkgs#chromium` → "will be fetched" is fine, "will be built" is not.
   Substituting Firefox for Chromium is pre-authorised by the plan; note it if you do.

3. **The Hypr* ecosystem's newer tools assume a real GPU.** hyprpaper 0.8 segfaults here —
   it asks GBM for `ABGR16161616F`, which virtio-gpu does not have, and dereferences the
   null (`phase-4.md` §3). swaybg replaced it. Anything else built on **hyprtoolkit** is
   suspect on this guest.

4. **The theme already has what ghostty needs.** `home/chime/theme/colors.nix` exports three
   vocabularies: `palette` (Tokyo Night's own names), `hex`/`css` (*roles* —
   `background`, `accent`, `warn`), and `terminal` (the ANSI 16). **Consumers read roles or
   `terminal`, never `palette` directly** — that is the theme-switcher seam. `home/chime/foot.nix`
   is the worked example; ghostty's colour config is the same list under different key names.

5. **`$terminal` in `home/chime/hyprland.nix` is still the single line** that switches foot
   → ghostty. Keep `home/chime/foot.nix`: a themed fallback that cannot be the reason a
   graphical test fails is worth the twenty lines. **`Super+B` is still unbound**, waiting
   for chromium.

6. **Nerd Font glyphs are written as codepoints, not pasted characters.** The Private Use
   Area does not survive a round trip through a file writer — Phase 4 lost every glyph in
   the waybar config, silently, and the bar rendered the padding with no icon
   (`phase-4.md` §1). `home/chime/theme/default.nix` has a `glyph` helper built on
   `builtins.fromJSON`; add to `icons` rather than inlining a character.

7. **home-manager will not always write the systemd unit you need.** mako's module installs
   a D-Bus service file naming `mako.service` and never creates it (`phase-4.md` §6);
   swaybg has no module at all. Both units are hand-written in `home/chime/`. Check
   `systemctl --user is-active <name>` after adding any daemon, and
   `systemctl --user list-units --state=failed` before declaring a phase done.

8. **`pkill -f` still kills the ssh session running it.** `phase-3.md` §7 said so, and Phase
   4 did it again: the pattern appears in the killing command's own command line. Use
   `pkill -x`. The symptom is exit code 255 and no output at all.
