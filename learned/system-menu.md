# The System menu, and the launcher bug it uncovered

Written 2026-09-06. The session had no discoverable way to log out — `Super+Shift+Q` is the
bind, and nothing on screen says so. Omarchy solves it with a **System** entry in the menu
its Super+Space opens, so that is what was copied.

## 1. Omarchy's menu is a Quickshell plugin now, and that part was not copied

Cloned `github.com/basecamp/omarchy` and read it rather than the README, the same way
`learned/phase-0.md` §3 read try-omarchy.

`bin/omarchy-menu` is a thin wrapper over `omarchy-shell shell toggle omarchy.menu`, and the
menu itself is a first-party Quickshell plugin driven by a JSONC definition
(`default/omarchy/omarchy-menu.jsonc`) whose rows look like:

```jsonc
"system":          {"icon":"","label":"System","aliases":["power-menu"]},
"system.lock":     {"icon":"","label":"Lock","action":"omarchy-system-lock"},
"system.suspend":  {"icon":"󰒲","label":"Suspend","when":"! omarchy-toggle-enabled suspend-off","action":"systemctl suspend"},
"system.logout":   {"icon":"󰍃","label":"Logout","action":"omarchy-system-logout"},
"system.reboot":   {"icon":"󰜉","label":"Reboot","action":"omarchy-system-reboot"},
"system.shutdown": {"icon":"󰐥","label":"Shutdown","action":"omarchy-system-shutdown"},
```

**Quickshell is a large dependency for four lines of shell**, and this repo already has the
same UI for free: `home/chime/hyprland.nix` was using `walker --dmenu` for the Super+K
keybindings cheat sheet before this. So the *structure* was borrowed — the entries, their
order, one script per action, a `when`-style guard for anything the machine cannot do — and
the machinery was not.

Two entries were dropped rather than translated. **Suspend**: this is a guest whose host
window is its display, and `systemctl suspend` inside it is not the gesture "sleep the Mac".
**Hibernate**: Omarchy guards it with `omarchy-hibernation-available`, and there is no swap
here to hibernate into.

`omarchy-system-lock` and friends are worth reading anyway for what a *complete* action does
— close windows first, OSD, `systemd-run --on-active=2s` so the reboot outlives the script.
Bento's are one-liners because there is nothing here that needs coaxing shut.

## 2. Two spellings that are load-bearing

- **Lock is `loginctl lock-session`, never hyprlock.** `home/chime/lock.nix` gives hypridle
  the `lock_cmd` and it answers logind's Lock signal, so going through logind keeps the
  menu, the Super+L bind and the 30-minute idle timeout on one code path. Calling hyprlock
  directly would stack a second lock screen on top of the first.
- **Logout is `hyprctl dispatch 'hl.dsp.exit()'`.** Under the Lua config manager a
  dispatcher argument is *evaluated as Lua*, so `hyprctl dispatch exit` fails
  (`learned/hyprland-lua.md` §3). From a launcher that failure is completely silent: the
  menu closes and nothing happens.

## 3. Discoverability is a desktop entry, not a keybind

A bind cannot fix "I have no idea how to log out", because finding it needs the cheat sheet
that the same problem hides. So the menu is also `xdg.desktopEntries.bento-system`, which
puts **System** one Super+Space and three letters away.

One entry that opens a menu, not four entries for the four actions: in a fuzzy launcher
that also lists editors and browsers, a row called *Shut down* is one mistyped Enter from
ending the session. Omarchy nests them for the same reason.

`Super+Escape` is bound as well, the way a power menu is usually reached.

## 4. The bug this uncovered: every rebuild left walker dead

Found while verifying the entry appeared. `walker.service` was `inactive (dead)` after the
rebuild, and had been stopped at the exact second home-manager activated.

`walker.service` carries `Requires=elephant.service`, and `home/chime/walker.nix` makes
elephant restart on **every rebuild that changes what is installed** — deliberately, because
elephant otherwise indexes desktop entries once at login and never again (Phase 5). The two
combine badly, and the reason it hides is that the obvious test does not reproduce it:

```
systemctl --user restart elephant   → walker stopped and started again    (fine)

systemctl --user stop elephant      → elephant inactive, walker inactive
systemctl --user start elephant     → elephant active,   walker STILL inactive
```

**home-manager's sd-switch stops and starts a changed unit rather than restarting it**, so
it is the second sequence that runs during a rebuild. `Requires=` takes walker down with
elephant, and nothing brings it back.

Nothing fails and no unit is marked failed. The only symptom is that Super+Space cold-starts
GTK4 on llvmpipe from then on — which `walker.nix` itself calls "the difference between a
launcher and a pause". It had presumably been happening after every package-changing rebuild
since Phase 5.

The fix is three lines: give `walker.service` the same `X-Restart-Triggers` elephant has, so
sd-switch sees it as changed too and starts it in the same pass. `After=elephant.service`,
which the home-manager integration already sets, keeps the order right.

> **The general shape, and it is the third instance in two days.** A rebuild quietly
> degrades the running session, nothing is marked failed, and the damage is only visible if
> you know what "good" looked like. The others are `learned/hyprland-lua.md` §8 (a config
> reload silently halves the desktop scale) and Phase 5's elephant index itself. **After a
> `bento rebuild switch`, check the session, not just `bento doctor`** — it reports failed
> units and will say `none` for all three of these.
