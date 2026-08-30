# What Phase 5 taught us

**Date:** 2026-08-30 · **Host:** Apple Silicon MacBook (M4), macOS 26.5.2 · **Guest:** NixOS
`26.11.20260828.83199d0`, ghostty **1.3.1**, chromium **152.0.7977.64**, neovim **0.12.5**,
claude-code **2.1.245**, nodejs-slim **24.19.0**, elephant **2.22.0**, walker **2.17.0**,
Hyprland **0.56.2**, `aarch64`
**Outcome:** ✅ Phase 5 complete — the v1 software list is installed, themed and launchable,
and Claude Code runs inside the VM up to the login prompt.

Findings log for Phase 5: my software and the agent. Everything here was measured inside
the running VM. Where it contradicts `PLAN-v1.md`, the earlier learned files or upstream
documentation, that is called out.

## Acceptance — verified

| Criterion | Result | How |
|---|---|---|
| `claude --version` works | ✅ `2.1.245 (Claude Code)` | over ssh |
| Smoke test `cd ~/bento && claude` | ✅ starts, renders, reaches **"Select login method"** | *typed on the emulated keyboard* into ghostty, read off the QEMU scanout |
| Ghostty launches from the Walker launcher | ✅ `activated=com.mitchellh.ghostty.desktop` | `--key meta_l-spc`, `--type Ghostty`, `--key ret` |
| Chromium launches from the Walker launcher | ✅ `activated=chromium-browser.desktop` | ditto |
| Neovim launches from the Walker launcher | ✅ `activated=nvim.desktop`, **in ghostty** | ditto |
| *(beyond the criteria)* Super+Return opens ghostty | ✅ `class=com.mitchellh.ghostty`, themed | `--key meta_l-ret` |
| *(beyond the criteria)* Super+B opens chromium | ✅ renders a live page over the network | `--key meta_l-b` |
| *(beyond the criteria)* chromium is the `xdg-open` default | ✅ `xdg-settings get default-web-browser` → `chromium-browser.desktop` | — |
| *(beyond the criteria)* `bento doctor` | ✅ reports *"in sync — the running system is this commit"* | — |
| `nix flake check` still green | ✅ exit 0 in 73 s, natively in the guest | — |
| Compositor still healthy | ✅ `hyprland.log` **12 107 bytes, 5 `ERR`** — byte-identical to the Phase 3/4 baseline | `hyprctl configerrors` empty |
| No failed units | ✅ system and user both empty | — |

**Only one thing was left for a human: logging Claude Code in.** Everything else was
driven from the host with `scripts/vm-screenshot.sh`. Seven `bento rebuild`s, no image
rebuild, no linux-builder.

**Three substitutions from PLAN-v1 §5, and two risks that did *not* fire:**

1. **`nodejs-slim` replaces `nodejs`** — the only place risk #2 lands in this phase. §2.
2. **"LazyVim-style" is a declarative plugin set, not LazyVim.** §5.
3. **`bento doctor` lives in `modules/bento-cli.nix`**, not `modules/agent.nix` where the
   plan puts it — `doctor` is a verb of `bento`, and that file owns the dispatch
   (`learned/phase-2.md` §6 named it as the seam). `modules/agent.nix` carries a comment
   saying so.
4. **Chromium was *not* substituted** (risk #2 pre-authorises Firefox) and **ghostty needed
   no fallback** — both are in the aarch64 binary cache. §2.

---

## 1. The launcher's index does not survive a rebuild

This is the phase's real bug, and it is the same shape as every other one this repo has
recorded: **everything looked right and the answer was wrong.**

Super+Space opened walker. It was themed, it took the query, it responded in a
millisecond — with *"Nothing matches"*, for `ghostty`, on a machine where `ghostty` was
installed, on `PATH`, had a desktop entry, and had already been opened by Super+Return.

The journal was where it broke:

```
16:53:41 INFO runner executables=1030 time=525.231417ms      ← scanned once, at login
16:54:11 INFO providers p=desktopapplications results=7
17:42:41 INFO providers p=desktopapplications results=7      ← still 7, three rebuilds later
17:42:43 INFO providers p=desktopapplications,calc,runner results=0
```

`results=7` before Phase 5 and `results=7` after it, while
`ls /etc/profiles/per-user/chime/share/applications/*.desktop` counted 12. And
`Active: since 16:53:25` — elephant had not restarted across *three* `bento rebuild`s.

**The mechanism is a Nix one, not an elephant bug.** A rebuild does not add a file to
`/etc/profiles/per-user/chime/share/applications`; it repoints that symlink at a **new
store path**. A scan of the old directory stays valid, and so does an inotify watch, which
follows the resolved inode. The index is not stale in the sense of being out of date with
the files it read — the files it read still exist, unchanged, forever. Nothing will ever
invalidate it.

`systemctl --user restart elephant` fixed it instantly, which is the diagnosis and not the
fix. The fix writes the profile paths into the unit:

```nix
systemd.user.services.elephant.Unit.X-Restart-Triggers = [
  config.home.path        # ghostty, chromium, neovim — home packages
  osConfig.system.path    # claude-code and the rest of environment.systemPackages
];
```

Any rebuild that changes what is installed changes that store path, which changes the unit
file, which makes home-manager's sd-switch restart the service. **Verified by adding a
package and watching `ActiveEnterTimestamp` move** (17:45:34 → 17:46:36) rather than by
assuming the mechanism works.

`osConfig.system.path` and **not** `osConfig.system.build.toplevel`: the latter depends on
home-manager's own generation, so asking for it from inside home-manager is an infinite
recursion.

> **Generalised lesson, and it is broader than elephant.** On NixOS, *any* long-running
> process that caches a scan of a profile directory is wrong from the next rebuild
> onwards, and cannot notice. If a daemon indexes `$PATH`, `XDG_DATA_DIRS`, a font
> directory or an icon theme, it needs a restart trigger. The usual "it'll pick it up
> eventually" intuition comes from distributions that mutate directories in place.

## 2. Package probes — and `nodejs_20` no longer exists

Re-run in the guest at the start of the phase (`nix build --dry-run nixpkgs#<attr>`;
"will be fetched" is fine, "will be built" is not), because `learned/HANDOFF.md` said to
re-run rather than trust its table. It was right to say so — one row had changed.

| Package | Version | Verdict |
|---|---|---|
| `ghostty` | 1.3.1 | ✅ 5 paths fetched (16.4 MiB) — **no substitution** |
| `chromium` | 152.0.7977.64 | ✅ 8 paths fetched (200.1 MiB) — **no Firefox substitution** |
| `neovim` | 0.12.5 | ✅ 17 paths fetched |
| `claude-code` | 2.1.245 | ✅ 32 fetched + 2 trivial derivations (the JS bundle and its wrapper) |
| `ripgrep` / `fd` / `gh` / `jq` / `curl` | — | ✅ fetched |
| `nil` / `lua-language-server` / `nixfmt-rfc-style` | — | ✅ fetched |
| **`nodejs`** | **24.19.0** | ❌ **builds from source** |
| **`nodejs-slim`** | **24.19.0** | ✅ **28 fetched, 0 built ← the substitution** |
| `nodejs_22` / `nodejs_24` | — | ❌ both build from source |
| **`nodejs_20`** | — | ❌ **gone from nixpkgs entirely** |

`nodejs` and `nodejs-slim` are the same Node at the same version; `nodejs` differs only in
carrying npm, and it is the npm wrapper that puts it off the cached path.

**The handoff's suggested alternative is dead.** `nodejs_20` does not evaluate any more:

```
error: Node.js 20 support was removed given upstream End-of-Life on 2026-04-30
```

It is a `throw`, not a warning — the evaluation stops, exactly like `noto-fonts-emoji` in
`learned/phase-4.md` §7. A findings log naming a specific package version is a perishable
thing; this one lasted about six hours.

**Probing `claude-code` by hand still needs the unfree escape hatch**, as the handoff said:
`nix build nixpkgs#claude-code` fails with an assertion from `lib/customisation.nix`,
because the bare `nixpkgs#` registry reference does not inherit the flake's
`nixpkgs.config.allowUnfree`. Use
`NIXPKGS_ALLOW_UNFREE=1 nix build --dry-run --impure nixpkgs#claude-code`.

## 3. `$TERMINAL` decides what `Terminal=true` means

`nvim.desktop` carries `Terminal=true`, so something has to choose the terminal. Launching
Neovim from walker opened it in **foot** — the fallback terminal — while Super+Return
opened ghostty. Two terminals, one desktop, depending on how you started the program.

elephant's binary carries both halves of the answer: a `TERMINAL` environment lookup, and
a hardcoded list of terminal binaries to scan for otherwise. That list is **not ordered by
preference** — `foot` simply comes before `ghostty` in it. With one terminal installed the
default is invisible; the fallback terminal `learned/phase-3.md` §8 insisted on keeping is
exactly what made it visible.

```nix
Service.Environment = [ "TERMINAL=${terminal}" ];
```

Two things about where that goes:

- **Not `environment.sessionVariables`**, which is the obvious home. That lands in
  `/etc/pam/environment` and is read once when the PAM session opens, so it would need a
  guest **reboot** rather than a rebuild (`learned/phase-4.md` §7). On the unit it arrives
  with the restart §1's trigger already causes.
- **The value is read back out of the Hyprland config**, not written twice:
  ```nix
  terminal = config.wayland.windowManager.hyprland.settings."$terminal";
  ```
  `$terminal` in `home/chime/hyprland.nix` stays the single place the terminal is named. A
  second literal would drift silently — the launcher would keep working and just open the
  other terminal.

## 4. nixpkgs ships nvim-treesitter's `main` branch, and the old setup call is a no-op

Every nvim-treesitter guide, and its own pre-2025 README, says:

```lua
require("nvim-treesitter.configs").setup { highlight = { enable = true } }
```

**That module does not exist in nixpkgs' nvim-treesitter.** `lua/nvim-treesitter/` holds
`init`, `config`, `install`, `parsers`, `indent`, `health` and nothing else, and `setup()`
now configures where `:TSInstall` *downloads* to — which on a machine whose parsers are a
read-only store path is not a question anyone is asking.

Highlighting moved into Neovim. `vim.treesitter.start()` is the whole feature, and
`withAllGrammars` puts both halves it needs on the runtimepath — as a **second plugin**
beside the first:

```
.../pack/hm/start/nvim-treesitter-grammars/parser/nix.so
.../pack/hm/start/nvim-treesitter-grammars/queries/nix/highlights.scm
```

So the replacement is a FileType autocmd, `pcall`ed because a filetype with no parser is
normal rather than an error:

```lua
vim.api.nvim_create_autocmd("FileType", {
  callback = function(ev) pcall(vim.treesitter.start, ev.buf) end,
})
```

Verified by opening `flake.nix` and asking the editor rather than the screen:
`vim.treesitter.highlighter.active[buf]` is non-nil and the parser reports `nix`.

**The failure was caught only because every plugin is set up through a wrapper**:

```lua
local function setup(name, opts)
  local ok, mod = pcall(require, name)
  if not ok then vim.notify("bento: plugin not found: " .. name, vim.log.levels.WARN) return end
  ...
end
```

It printed `bento: plugin not found: nvim-treesitter.configs` on every start and left a
working editor. The bare `require(...).setup{}` form would instead have produced an editor
that fails to start — *from which the config that caused it cannot be edited*. On a machine
whose editor is how you fix the machine, that wrapper is not defensive style, it is the
difference between a warning and a recovery.

## 5. LazyVim-style, not LazyVim — and why

`PLAN-v1.md` §5 step 3 asks for *"LazyVim-style via home-manager (`programs.neovim` +
LazyVim config files; don't over-engineer with nixvim in v1)"*. What landed is LazyVim's
plugin set, LazyVim's keymap scheme and LazyVim's own default colorscheme (tokyonight —
the upstream source of the palette `home/chime/theme/colors.nix` transcribes), with every
plugin from nixpkgs and nothing fetched at runtime.

LazyVim itself is not installed, deliberately:

1. **It is a plugin manager at runtime.** LazyVim is a lazy.nvim configuration, and
   lazy.nvim's job is to `git clone` some fifty repositories into `~/.local/share/nvim` on
   first launch. On a machine whose whole premise is that its software list is a flake,
   that is the one component that would not be — and it makes "does the editor work?" a
   question about GitHub's availability.
2. **It wants to own `~/.config/nvim`**, which home-manager is filling with read-only
   store symlinks. Not merely redundant; they collide.
3. `vimPlugins.LazyVim` *is* in nixpkgs, so a middle path exists (LazyVim as a Nix plugin
   with lazy.nvim told not to install anything). That is nixvim-shaped complexity, which
   the plan explicitly rules out for v1.

The genuine loss is `:LazyExtras` and the per-language presets. Adding a plugin is now a
line in `home/chime/neovim.nix` plus a `setup()` call in `home/chime/neovim/init.lua`.

**On the "will be built" rows in the plugin probe:** several plugins report *"this
derivation will be built"*, and unlike `nodejs` that is fine. A `buildVimPlugin` is an
unpack and a copy of an already-fetched source — seconds, not a compile. Risk #2 is about
source builds of large packages; reading it as "never build anything" would rule out
almost every vim plugin in nixpkgs for no benefit.

The Lua lives in `home/chime/neovim/init.lua` and reaches the module through
`builtins.readFile`, not as a Nix string. It contains no `${...}`, so nothing is lost, and
it stays a file that an editor, a formatter and `lua_ls` can all read. (`home/chime/neovim`
is therefore a directory in `home/chime/` that is *not* a home-manager module — the same
status `./theme` has.)

## 6. Ghostty and Chromium both work on llvmpipe — and one Phase 4 prediction was too broad

Neither needed a workaround. Both were verified off the QEMU scanout, not from a log:
Super+Return produced a ghostty window whose interior was **96.9 % `#1a1b26`** — the
theme's own background, sampled straight out of the PNG — and `ghostty +show-config`
confirmed the resolved palette matched `home/chime/theme/colors.nix` exactly.

**`learned/phase-4.md` §8 predicts: *"Anything GTK 4 in Phase 5 depends on
[`GSK_RENDERER=cairo`]."* Ghostty is GTK 4 and does not.** Measured by launching it with
the renderer Phase 4 had shown drawing *nothing* for walker:

| launched with | result |
|---|---|
| `GSK_RENDERER=cairo` (the session default) | ✅ draws — 96.9 % `#1a1b26` |
| `GSK_RENDERER=gl` | ✅ **draws identically** — 96.9 % `#1a1b26` |

The distinction is what the toolkit is being asked to draw. Walker is GTK 4 widgets all
the way down, so GSK's renderer *is* its renderer. Ghostty draws its own terminal grid and,
with `window-decoration = none`, hands GSK almost no widget chrome to compose.

**`GSK_RENDERER=cairo` stays** — walker still needs it, and that was measured four ways in
Phase 4. What changes is the scope of the claim: it is not "GTK 4 is broken here", it is
"GSK's widget rendering is broken here", and an application that bypasses GSK for its
content is unaffected.

Chromium's flags are chosen rather than discovered:

- `--disable-gpu` — there is no GPU behind virtio-gpu. Left alone Chromium starts a GPU
  process, fails to get a usable GL context and restarts it, which is the same shape of
  invisible retry loop `LIBGL_ALWAYS_SOFTWARE` produced in aquamarine
  (`learned/phase-3.md` §2).
- `--password-store=basic` — otherwise it looks for gnome-keyring or kwallet, finds
  neither on a Hyprland-only session, and blocks on the lookup at startup.
- `--ozone-platform=wayland` — `OZONE_PLATFORM` is already in the session environment, but
  that variable reaches a process only through PAM and needs a reboot to change
  (`learned/phase-4.md` §7). A flag cannot be out of date.

**Neither added a single line to the compositor log.** `hyprland.log` is still **12 107
bytes with 5 `ERR`** — byte-for-byte the Phase 3 baseline, with a browser and two terminals
running.

## 7. `writeShellApplication` runs shellcheck, and shellcheck dies on your em-dashes

`bento doctor`'s first version failed the build on **SC2059**, which shellcheck rates
*info*:

```
printf "$field" "generation" "${generation:-unknown}"
       ^------^ SC2059 (info): Don't use variables in the printf format string.
```

`writeShellApplication` treats it as fatal, so a `local field="%-15s %s\n"` reused as a
format string is not a style note, it is a broken system build. The format has to be a
literal at every call site.

The more interesting half is what the error output looked like:

```
In /nix/store/...-bento/bin/bento line 192:
/nix/store/...-bento/bin/bento: <stdout>: commitBuffer: invalid argument
                                (cannot encode character '\8212')
    printf "$field" "state" "MISSING For more information: ...
```

`\8212` is **U+2014, an em-dash**, in a comment. shellcheck's stdout has no UTF-8 locale
inside the Nix build sandbox, so printing the offending source line **kills shellcheck
itself**, truncating the diagnostics mid-sentence and interleaving them with its footer.

This only bites when there is already an error to report — every other file in this repo is
full of em-dashes and builds fine. But it means the first failure in a
`writeShellApplication` containing non-ASCII produces a *garbled* message, and the missing
part is usually the rest of the list of problems.

> Same family as `learned/phase-4.md` §1's Private Use Area glyphs, from the other end:
> there the bytes did not survive being *written*, here they do not survive being *reported*.

## 8. Reading colours off the scanout without PIL

`scripts/vm-screenshot.sh` makes the QEMU scanout the authority, and Phases 3–4 read it by
looking at the picture. That answers "is something there?" but not "is it the right
colour?", and macOS ships no PIL to ask with.

A PNG is `zlib` plus five filter types, which is about forty lines of standard library. The
throwaway used here reported that the ghostty window was 96.9 % `#1a1b26` — a *number*
compared against `home/chime/theme/colors.nix`, rather than a judgement about a thumbnail.
Worth rebuilding, or promoting into `scripts/`, the next time a phase has to prove a colour.

## 9. Smaller things worth carrying forward

| Thing | Detail |
|---|---|
| **`nix build --dry-run \| tail -n` hides the verdict** | The "will be built" / "will be fetched" line comes *first*, followed by the path list. Tailing the output of a probe drops the only line the probe exists to produce. Grep for the verdict. |
| **home-manager's ghostty module validates for you** | `xdg.configFile."ghostty/config".onChange` runs `ghostty +validate-config`, so a bad key fails at activation rather than on screen. `ghostty +show-config` then prints the *resolved* config, themes included — the honest answer to "did the theme apply?". |
| **Ghostty's `palette` is a repeated key** | `palette = 0=#1a1b26`, sixteen times. The module builds the file with `listsAsDuplicateKeys`, so a Nix list of strings is exactly right and no line-joining is needed. |
| **`resize-overlay` and `cursor-style-blink`** | Both default to something that a screenshot catches at the wrong moment — an overlay on every geometry change, and a cursor that is absent half the time. Same reasoning as hyprlock's `fade_on_empty` (`learned/phase-4.md` §5): on a machine inspected through screenshots, anything on a timer will eventually be reported as missing. |
| **`chromium-browser.desktop`, not `chromium.desktop`** | The name nixpkgs installs, and what `xdg.mimeApps.defaultApplications` has to say. `xdg-settings get default-web-browser` is the check. |
| **`xdg-utils` is not pulled in by anything** | The portals provide the Wayland open-uri path, not the `xdg-open` CLI. `walker`'s websearch provider needs the CLI. |
| **walker's `websearch` provider is back on** | Phase 4 dropped it because there was no browser to hand a URL to. It opens its result with `xdg-open`, which now resolves to chromium. |
| **`environment.systemPackages` tolerates duplicates** | `jq` is in both `desktop.nix` (the Hyprland reload hook calls it by bare name) and `agent.nix` (which has to stand up on a headless bento). Identical store paths deduplicate. |

## 10. Settled for later phases — do not re-litigate

- **A daemon that indexes a Nix profile needs a restart trigger** (§1). If Phase 6 or later
  adds anything that scans `PATH`, `XDG_DATA_DIRS`, fonts or icons at startup, give it
  `X-Restart-Triggers` pointing at `config.home.path` / `osConfig.system.path` — and never
  `system.build.toplevel`, which recurses.
- **`nodejs-slim`, never `nodejs`** (§2), until someone checks the probe again. `nodejs_20`
  is gone and is not coming back.
- **`$terminal` in `home/chime/hyprland.nix` is still the only place the terminal is
  named**, and `home/chime/walker.nix` reads it back rather than repeating it (§3).
  `home/chime/foot.nix` stays: it is the fallback that cannot be the reason a graphical
  test fails, and in this phase it was also the thing that *exposed* the `$TERMINAL` bug.
- **Neovim's plugins are set up through the `setup()` wrapper** (§4). A bare
  `require(...).setup{}` trades a warning for an editor that will not start.
- **`GSK_RENDERER=cairo` stays, but the claim around it is narrower than Phase 4 wrote it**
  (§6). Test a GTK 4 application rather than assuming it is affected.
- **Claude Code's credentials are the one manual step.** The token lands in `~/.claude` in
  the guest, which survives every `bento rebuild` and does **not** survive the clean loop
  (`build-image.sh` replaces the disk). Re-login is part of the cost of a re-image.
- **The mouse cursor is still Hyprland's default teal droplet.** Unchanged from Phase 4,
  still the last unthemed thing on the desktop, still out of scope.
