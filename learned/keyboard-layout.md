# Keyboard layout — giving the guest a Danish Mac keyboard

Measured 2026-09-05/06, in the VM. HANDOFF Task 2, mostly done; one finding below belongs
to Task 1 instead and is flagged as such. Phases 0–6 are in `learned/phase-*.md`;
`learned/keyboard-capture.md` covers the *other* half of the keyboard problem — that one is
about which host keys reach the guest, this one is about what the guest makes of them.

The symptom: the guest read a Danish Mac keyboard as US. QEMU's virtio keyboard forwards
raw scancodes rather than the characters macOS resolved, so the host knowing its own layout
buys the guest nothing — the layout has to be named again inside.

Everything below was compiled with `xkbcli compile-keymap` against the xkb tree actually
installed on this machine, or read out of `xkeyboard-config-2.48`, rather than taken from
documentation.

## 1. `dk(mac)` is a stub over the *PC* Danish layout

The obvious first move — `kb_layout = "dk"`, `kb_variant = "mac"` — gets you close and then
stops. `xkeyboard-config-2.48`'s entire definition is:

```
xkb_symbols "mac" {
    include "dk(basic)"
    name[Group1]= "Danish (Macintosh)";
    key <AB10>	{[    minus,  underscore,       hyphen,       macron ]};
    key <SPCE>	{[    space,       space, nobreakspace, nobreakspace ]};
    include "kpdl(dot)"
};
```

Two keys. `dk(basic)` is the **Windows/PC** Danish layout, so every symbol Apple places
differently is simply wrong, and the variant name promises far more than it delivers. This
is why the layout felt *nearly* right: the letters are all correct and only the symbols
that PCs and Macs disagree about are misplaced.

Concretely, the first one found: `@` sits on AltGr+2 (the PC convention) because
`dk(basic)` leaves `<BKSL>`'s third level as `dead_doubleacute`:

```
key <BKSL>	{[apostrophe,  asterisk, dead_doubleacute,  multiply ]};
```

Apple puts `@` on Option+' — `<BKSL>`, the key immediately left of Return.

## 2. Left-Option was a *modifier* problem, not a layout one

"`@` is on R-opt, it should be on L-opt" reads like one bug and is two. The half that no
custom layout would have fixed: xkb's default binds the third level to the right Alt alone.
Compiled with no options at all:

```
key <LALT> {	[ Alt_L ] };
key <RALT> {	type= "ONE_LEVEL", symbols[1]= [ ISO_Level3_Shift ] };
```

macOS treats the two Options alike, so Left-Option was not "wrong", it was **inert** for
symbols. The fix is an option rather than a symbols file — `lv3:alt_switch` ("Any Alt"),
set in `home/chime/hyprland.nix`. After it, both are `ISO_Level3_Shift`.

Worth separating when the next difference turns up: *where a symbol lives* is the layout,
*which key reaches level 3* is the option. They are fixed in different files.

## 3. Registering a layout, rather than pointing at a file

`services.xserver.xkb.extraLayouts` (in `modules/desktop.nix`, symbols in
`modules/xkb/dkmac`) is the right mechanism even though Hyprland also accepts a bare
compiled keymap via `input:kb_file`. The NixOS module patches the layout into `evdev.xml`
and `base.lst` and — the part that matters —

```nix
# nixos/modules/services/x11/extra-layouts.nix:144
environment.sessionVariables = { XKB_CONFIG_ROOT = config.services.xserver.xkb.dir; };
```

sets `XKB_CONFIG_ROOT` session-wide, reaching Hyprland through `/etc/pam/environment`. So
the compositor, the greeter and any future `console.keyMap` all resolve the same name.
`kb_file` would have given the layout to Hyprland alone.

The symbols file `include`s the stock layout and overrides one key at a time, which keeps
the diff against upstream readable as the list of Apple-vs-PC differences it actually is.

## 4. The trap: an unloadable layout falls back to `us`, silently

`kb_layout = "dkmac"` in a session started *before* `XKB_CONFIG_ROOT` existed produced a
working keyboard in US, not an error. `hyprctl devices` reported `l "us"` with no
indication that it had been asked for anything else. The name resolves at keymap creation,
and libxkbcommon's failure path is a fallback, not a refusal.

Hyprland does log it — but **not by default**:

```
ERR ]: Keyboard layout dkmac with variant  (rules: , model: , options: lv3:alt_switch)
       couldn't have been loaded.
```

Getting that line out took `debug.disable_logs = false`. Hyprland 0.56.2 writes *none* of
its own messages to `$XDG_RUNTIME_DIR/hypr/<instance>/hyprland.log` unless asked; what does
keep writing is **aquamarine**, which has a separate logger the setting does not govern. An
untouched log is therefore not empty — it is full of libinput debounce noise, which reads
like a healthy log while every line that matters is dropped. The file says so itself, once:

```
!!!!HEY YOU, YES YOU!!!!: further logs to stdout / logfile are disabled by default.
```

Same shape as `phase-6.md` §3 and `keyboard-capture.md` §5: a silent failure whose output is
indistinguishable from a pass. `grep -v 'from aquamarine'` is how to read the file at all.

To test a layout without logging out — the loop that made this tractable:

```sh
# XKB_CONFIG_ROOT is already exported in a session started after the layout was added; this
# resolves it by hand for one that was not. xkbcli is not on PATH — libxkbcommon ships it.
R=$(grep '^XKB_CONFIG_ROOT' /etc/pam/environment | sed 's/.*DEFAULT="//; s/"$//')
XKB_CONFIG_ROOT="$R" nix shell nixpkgs#libxkbcommon -c \
  xkbcli compile-keymap --layout dkmac --options lv3:alt_switch | grep 'key <BKSL>'
```

It compiles against the installed tree, so it catches both syntax errors and wrong
bindings, and it is unaffected by what the running compositor believes.

## 5. Task 1: the display *is* HiDPI, contradicting `phase-0.md` §3

Measured while chasing "the letters got small", and it belongs to Task 1 rather than here.

`scripts/run-vm.sh` asks for `xres=1920,yres=1080`, but the guest is handed **3840x2412**:

```
/sys/class/drm/card0-Virtual-1/modes → 3840x2412   (preferred)
```

That is exactly 2× 1920×1206 — the Retina backing store of a Cocoa window of that many
points. (The scanout is measured; that it is a *backing store* is inference — the host
window was not measured from inside the guest.) `home/chime/hyprland.nix` hardcoded
`scale 1` on the stated grounds that the Cocoa display is not HiDPI-aware without
try-omarchy's patch, so every glyph rendered at half size.

Two consequences. `scale 2` is the correct fix rather than a workaround — 3840/2 and 2412/2
are both integers, so it divides cleanly at no cost in sharpness. And the handoff's open
question about dynamic resize — *"how much we already have is unknown and is the first
thing to measure rather than assume"* — now has a partial answer: **the guest followed the
host window to a resolution nobody asked for**, which points at the GL series' changes to
`cocoa.m`'s `updateUIInfo`/`resizeWindow` doing real work. Not the whole of Task 1, but no
longer unknown.

## 6. What this breaks

**`scripts/vm-screenshot.sh --type` is now wrong**, exactly as HANDOFF warned. Its
keystrokes go through QMP `sendkey`, which injects *physical key positions* into the
emulated keyboard; the guest's xkb then decides what they mean. Under `dkmac` a US-position
string no longer types what it says — and that tool is how every graphical test since
Phase 3 has been verified. `--key` for compositor binds is unaffected (modifiers and
Return are position-stable); it is `--type`'s ASCII that breaks. Unresolved.

**Left Alt is no longer Alt.** `lv3:alt_switch` makes it purely `ISO_Level3_Shift`, so
shell Meta bindings — `Alt+B`, `Alt+F`, `Alt+.` — are gone inside terminals. Nothing in
`home/chime/hyprland.nix` binds ALT (`$mod` is SUPER), so the compositor is unaffected. This
is the same trade macOS itself makes, and it is the cost of the fix in §2.

Note also `keyboard-capture.md` §4's warning in reverse: `swap-opt-cmd` would move Alt as
well as Super, so it is no longer free now that Alt carries level 3.

## Still unmeasured

**`dkmac` loads.** Observed 2026-09-06 in a greetd session after the reboot in
`hyprland-lua.md` §7: `hyprctl devices` reports `layout=dkmac active=Danish (Apple)` on
both `qemu-virtio-keyboard` and `power-button`, so PAM does supply `XKB_CONFIG_ROOT` to
an autologin session. This was the open question here and it is closed.

**The rest of the Apple-vs-PC differences are unenumerated.** `@` was found by using the
machine; §1 means there are almost certainly more. They go into `modules/xkb/dkmac` one key
at a time, tested with §4's one-liner.

**The TTY is still US.** `console.keyMap` is unset, so tty1 and `agreety` — the login prompt
in `modules/desktop.nix` — do not follow the compositor. It matters only when Hyprland has
failed to start, which is exactly when a password has to be typed.

## Three more keys, found on the hardware (2026-09-06)

Reported by pressing the key and naming the wanted symbol, which is a reliable way to
specify them: the character a key produces *now* names it unambiguously, because only one
key in the layout produces any given symbol at any given level.

| xkb key | where it is | was | is now |
|---|---|---|---|
| `<TLDE>` | left of `1` | `½ § ¾ ¶` | `< > ¾ ¶` |
| `<LSGT>` | left of `Z` | `< > \ ¬` | `$ § \ ¬` |
| `<AE04>` | the `4` | `4 ¤ $ ¼` | `4 € $ ¼` |

The first two are a swap of levels 1–2 between two keys that a PC Danish layout spends the
other way round. **Levels 3 and 4 were deliberately left alone on both**, which keeps
backslash on Option+`<LSGT>`; moving it along with the rest would be a quiet regression on a
machine used for code. `$` therefore now exists twice, on Shift+`<LSGT>` and Option+`4`,
which is the same trade §1 makes for AltGr+2.

### Verifying a layout change without logging out

`XKB_CONFIG_ROOT` is a store path baked into the session environment at login, so a rebuild
does **not** reach the running compositor — and `hyprctl eval 'hl.config({ input = {
kb_layout = "dkmac" } })'` recompiles the keymap from the *old* root, so it is no help
either. A relogin is the only way to see the change live.

What can be checked first, and it catches everything except the keys themselves:

```sh
NEW=$(nix eval --raw '.#nixosConfigurations.bento-vm.config.services.xserver.xkb.dir')
XKBC=$(nix build --no-link --print-out-paths nixpkgs#libxkbcommon)
XKB_CONFIG_ROOT="$NEW" $XKBC/bin/xkbcli compile-keymap --layout dkmac --options lv3:alt_switch \
  | grep -E 'key <(AE04|TLDE|LSGT)>'
```

That compiles the real deployed root — not the source file — so it proves the NixOS module
merged the layout, that `rules/evdev.xml` still registers it, and that every level is what
was asked for. `xkbcli` is not in the image; `nix build nixpkgs#libxkbcommon` fetches it.
