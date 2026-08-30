# Keyboard capture — giving Super+Space to the guest instead of Spotlight

Measured 2026-08-30, after v1. Not a phase: a standalone change to `scripts/run-vm.sh`
prompted by the launcher being unreachable. Phases 0–6 are in `learned/phase-*.md`; the two
tasks in `learned/HANDOFF.md` are still untouched.

The symptom: the desktop's whole keymap hangs off Super (`home/chime/hyprland.nix` sets
`$mod = SUPER`), and Super+Space — the launcher — did nothing, because macOS opened
Spotlight instead.

Everything below was read out of `ui/cocoa.m` in the QEMU we actually build
(`~/.local/state/bento/qemu-gl-src/qemu-10.1.2`) or measured against the two binaries on
this host, rather than taken from documentation.

## 1. Super *is* the Command key, and only while the mouse is grabbed

Two separate facts, and the second is the one that isn't obvious.

Cocoa maps the Mac's Command key to `Q_KEY_CODE_META_L` by default — `swap_opt_cmd` is
false unless asked for (`cocoa.m:88-89`, `cocoa.m:937-947`). So Omarchy's Super+X scheme
arrives as Cmd+X on this host, with no configuration at all.

But the Command branch is guarded:

```c
/* Don't pass command key changes to guest unless mouse is grabbed */
case kVK_Command:
    if (isMouseGrabbed && ... && left_command_key_enabled) {
```

`isMouseGrabbed` is not about the pointer being captured in the pointer-warping sense. With
`-device usb-tablet` the guest has an absolute pointing device, so `isAbsoluteEnabled` is
true and QEMU never needs to confine the cursor — but it still sets the flag, in
`mouseEntered:` (`cocoa.m:1086-1090`). **Moving the pointer into the window is what arms
the Command key**, `mouseExited:` disarms it, and `windowDidResignKey:` disarms it too.
Option, Control and every ordinary key are forwarded unconditionally; Command is the
exception.

Consequence for `learned/HANDOFF.md` Task 1: `windowDidEnterFullScreen:` calls `grabMouse`
and `windowDidExitFullScreen:` calls `ungrabMouse` (`cocoa.m:1353-1361`). A genuine
full-screen mode therefore holds the grab for as long as it lasts, and these two features
are more entangled than they look.

## 2. `full-grab=on` is a CGEventTap, and it fails without failing

macOS consumes system hotkeys before AppKit delivers anything to the application, so
Cmd+Space never reaches QEMU on the ordinary path no matter what the guest wants.
`full-grab=on` installs a tap ahead of that handling (`cocoa.m:710`):

```c
eventsTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                             mask, handleTapEvent, self);
if (!eventsTap) {
    warn_report("Could not create event tap, system key combos will not be captured.\n");
    return;
}
```

Three things follow:

- **It is scoped, not global.** `handleTapEvent` returns the event untouched unless
  `[view isMouseGrabbed]` (`cocoa.m:290-299`). Spotlight and Cmd+Tab keep working
  everywhere except inside the VM window.
- **A missing permission is a warning, not an error.** QEMU boots normally with no grab.
  There is no dialog either: QEMU calls `CGEventTapCreate` directly rather than
  `AXIsProcessTrustedWithOptions` with a prompt, so nothing asks — the tap simply returns
  NULL. That one `warn_report` line on the serial console is the entire diagnosis, which is
  why `run-vm.sh` now prints a banner telling you to watch for it.
- **The permission belongs to the terminal, not to qemu.** TCC attributes a command-line
  binary's request to the application that owns the process tree. Here that is Ghostty
  (`TERM_PROGRAM=ghostty`, `com.mitchellh.ghostty`), and adding it takes a manual **+** in
  System Settings → Privacy & Security → Accessibility, followed by a full quit and relaunch
  — TCC status is read at process start, so a running terminal keeps its old answer and so
  does every shell beneath it.

## 3. Both QEMUs accept the option

Worth checking, because `--no-gl` runs a different binary and an unknown `-display` option
would break the fallback. Measured with a deliberately invalid value:

```
$ qemu-system-aarch64 -display cocoa,full-grab=bogus                       # Homebrew 11.1.1
qemu-system-aarch64: -display cocoa,full-grab=bogus: Parameter 'full-grab' expects 'on' or 'off'
$ ~/.local/state/bento/qemu-gl/bin/... -display cocoa,full-grab=bogus      # ours, 10.1.2
qemu-system-aarch64: -display cocoa,full-grab=bogus: Parameter 'full-grab' expects 'on' or 'off'
```

Both know it. The same test also shows that `-display` is parsed *before* the display is
initialised, so a bad option is a clean exit rather than anything worse — which matters
given §5.

## 4. What was rejected, and why it is still the fallback

`swap-opt-cmd=on` makes Option the Super key instead of Command. It needs no permission at
all, because Option+Space is not a macOS hotkey, and it puts Super where a PC keyboard's
Super key physically sits. It was not chosen: it costs a permanently swapped Option/Command
mapping inside the guest to insure against a one-time setup step whose failure is visible
within seconds. `--no-grab` is the escape hatch instead, and it changes no mapping.

Note `left-command-key=off` exists as a third position — it stops the left Command reaching
the guest at all, so host Cmd+Tab keeps working while the VM has focus. Not used here, but
it is the option to reach for if the grab turns out to be too total.

## 5. The trap: never probe the Cocoa display without a GPU device

Trying to test the option without disturbing the running VM, this looked reasonable:

```bash
qemu-system-aarch64 -machine virt -nodefaults -S -display cocoa,full-grab=on
```

It segfaults, immediately and silently:

```
EXC_BAD_ACCESS  KERN_INVALID_ADDRESS at 0x38
  qemu_console_surface
  cocoa_display_init
  qemu_init_displays
```

`-nodefaults` leaves no `QemuConsole` for the Cocoa display to attach to, and
`cocoa_display_init` dereferences it. What makes this worth writing down is how it looks
from a script: **the process dies before it reaches `setFullGrab`, so it writes nothing to
stderr, and an empty log reads exactly like success.** The first probe was scored as "no
warning, therefore the tap was created". It had proved nothing at all. Three crash reports
in `~/Library/Logs/DiagnosticReports/` were the only evidence.

Same shape as `learned/phase-6.md` §3, where a black screenshot looks like a black desktop:
a silent failure whose output is indistinguishable from a pass. Assume nothing was measured
until something *positive* has been observed.

## 6. What this does not touch

`scripts/vm-screenshot.sh` is unaffected in both modes. Its keystrokes go through QMP
`sendkey`, which injects directly into the emulated USB keyboard and never involves the
host's — so `--key meta_l-spc` opened the launcher throughout Phases 3–6 while a human
pressing the same combination could not, and it keeps working with `--no-grab`.

Nor does it interact with HANDOFF Task 2 (keyboard layout): the grab decides *which host
keys reach the guest*, and xkb decides *what the guest makes of them*. Independent layers.
The one thing to keep in mind is that `swap-opt-cmd` would move Alt as well as Super, so if
Task 2 ever adds an `alt_shift_toggle` layout switch, §4's rejected option stops being free.

## Still unmeasured

**Whether the Accessibility grant actually produces a working tap on this machine has not
been tested.** It cannot be: QEMU dies before creating its window when launched from an
agent's sandboxed shell, and the grant has to be made by a human in System Settings anyway.
The next session should confirm it and record the result here — including whether launching
`run-vm.sh` *through the agent* behaves differently from launching it in a plain Ghostty
tab, since the process tree is `Ghostty → zsh → Claude → bash → qemu` in the first case and
the responsible process may resolve differently.
