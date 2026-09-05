# Keyboard capture — giving Super+Space to the guest instead of Spotlight

Measured 2026-08-30, after v1. Not a phase: a standalone change to `scripts/run-vm.sh`
prompted by the launcher being unreachable. Phases 0–6 are in `learned/phase-*.md`; the two
tasks in `learned/HANDOFF.md` are still untouched.

> **Final result, 2026-09-05:** Accessibility was a false lead on this host. An authorised
> HID event tap receives Command but not Space. A minimal native probe established that
> disabling Spotlight symbolic hotkey 64 while the window is focused and registering
> Cmd+Space with Carbon does receive the chord without a privacy grant. Bento's patched
> QEMU now uses that route and writes activation/forwarding evidence to
> `artifacts/bento-app.log`. Sections 7, 11, and 12 preserve earlier experimental history
> but their permission-based conclusions are superseded by §13.

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
  does every shell beneath it. **§7 refines this**: the grant was measured working from a
  process tree with no Ghostty in it at all, so "the application that owns the process tree"
  is looser than it sounds here.

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

## 7. Measured: the tap is real, and `isMouseGrabbed` is the gate that decides everything

Measured 2026-08-30/31, after Accessibility was granted to Ghostty and Cmd+Space *still*
opened Spotlight. Three false trails were paid for here; all three are worth keeping.

### The grant works, and the agent's process tree is irrelevant

`run-vm.sh` was launched from the agent's shell, whose tree contains no Ghostty at all:

```
launchd(1) -> herdr server(68545) -> zsh(72399) -> claude(82633) -> bash -> qemu
```

A tap created from that tree nevertheless **receives real keystrokes** — 60 s of listening
caught 4 key events against 14 counted by the HID counter. So the permission is fine, and
§2's "the permission belongs to the terminal" is looser than it reads: this tree works.

### False trail 1 — `CGEventTapCreate` returning non-NULL proves nothing

It is the §5 trap again in a new costume. A tap can be created *and report
`CGEventTapIsEnabled == true`* while receiving nothing. Only observing a real event arrive
counts.

### False trail 2 — you cannot test your own tap with `CGEventPost`

The obvious self-contained probe — create the tap, post a synthetic key, see if it comes
back — **always reports failure**, because an event posted by a process is not delivered to
that same process's taps (the loop-prevention rule). The `CGEventSourceCounterForEventType`
HID counter confirmed the post landed while the tap saw zero. That combination reads
exactly like "the tap is blocked" and is not. A human pressing a real key is the only test.

### False trail 3 — `kCGSSessionSecureInputPID` is not the smoking gun it looks like

`ioreg -l -d 1 -w 0 | grep kCGSSessionSecureInputPID` reports **593 = loginwindow** on this
machine as its *idle* state, not as an active block: the tap received real keystrokes with
that value unchanged. Do not read a non-zero value here as "secure input is eating the
keys".

### What actually gates it: `isMouseGrabbed`, on two independent paths

Both of these must pass, and both test the same flag (`ui/cocoa.m`, 10.1.2):

```c
/* 294 — the tap itself */
if ([view isMouseGrabbed] && [view handleEvent:event]) return NULL;   /* captured */
return cgEvent;                                                       /* -> macOS */

/* handleEventLocked, case NSEventTypeKeyDown */
if (!isMouseGrabbed && ([event modifierFlags] & NSEventModifierFlagCommand)) return false;
```

So **with the grab off, Cmd+Space is handed to macOS and Spotlight opens — with the tap
working perfectly.** That is the reported symptom, and it is not a permission fault.

The grab is armed only by the pointer *crossing into* the window (`mouseEntered:` at 1085,
guarded by `isAbsoluteEnabled`, which `query-mice` confirms: `QEMU HID Tablet
current=true absolute=true`). A pointer that was already inside when the window appeared
has fired no crossing. `windowDidResignKey:` and `mouseExited:` both disarm it.

**The window title is the live readout**, written by `grabMouse`/`ungrabMouse` (1150-1166):

| Title | State |
|---|---|
| `QEMU bento - (Press ⌃ ⌥ G to release Mouse)` | grabbed — Cmd goes to the guest |
| `QEMU bento` | not grabbed — Cmd goes to macOS |

Read the title before diagnosing anything else.

### Still unobserved

A human pressing Cmd+Space *with the title showing the grab*. Everything up to that point
is measured; that last step needs a person at the machine.

### Tooling note

Reading the title from a script needs macOS **Automation** or **Screen Recording**
permission, which is a *different* grant from Accessibility and is not held here —
`osascript ... System Events` fails with `-1743 Not authorised to send Apple events`. So an
agent cannot check the grab state; only the person looking at the window can.

## 8. False conclusion: try-omarchy solves it outside `full-grab`

Read out of `github.com/themartiano/try-omarchy` (shallow clone, 2026-08-31) after Cmd+Space
kept reaching Spotlight *with the grab confirmed on*. The headline: **they do not rely on
QEMU's event tap to capture Command chords.** They pass `full-grab=on` too, but their own
`qemu-cocoa-immersive-mode.patch` repurposes it as the *immersive fullscreen* flag —
it gates chrome-hiding, and gates the Command branches behind a new `full_grab_enabled`.

The Command→Super path is a **separate host-side helper process**,
`macos/Sources/OmarchyVMHelper/FocusedCommandSuperBridge.swift` (691 lines), started
alongside QEMU as `--bridge-command-super <qemu-pid> <qmp-socket>` and guarded by
`AXIsProcessTrusted()`. Its own doc comment states the design:

> Command itself is sent to QEMU through QMP as guest Meta. The rest of a Command chord is
> reposted directly to QEMU with only the Command flag removed. That avoids both macOS
> shortcuts and QEMU Cocoa's deliberate refusal to forward ungrabbed Command chords.

Concretely, per keystroke while QEMU is frontmost:

| Step | Mechanism |
|---|---|
| Tap | `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap)` — **session** tap, not `kCGHIDEventTap` as QEMU uses |
| Focus gate | `NSWorkspace.shared.frontmostApplication?.processIdentifier == qemuPID`, plus an AX check, re-polled on a 0.05 s timer |
| Command key | suppressed on the host; injected into the guest as `meta_l` **down/up** over QMP `input-send-event` with `{"type":"key","data":{"key":{"type":"qcode","data":"meta_l"}}}` — `input-send-event`, not `sendkey`, because Meta must be *held* across the chord |
| The other key | `CGEvent.postToPid(qemuPID)` **with `.maskCommand` stripped**, so QEMU sees a plain Space and no host shortcut ever matches |
| Recursion guard | reposted events carry marker `0x004F_4D41_5243_4859` (`"OMARCHY"`) in a user field; the tap ignores its own reposts |
| Ordering | the QMP write is completed synchronously *before* the chord key is reposted, or a fast chord outruns its own Meta-down |

Why this is strictly better than what we do:

- **It never depends on `isMouseGrabbed`.** §7's gate disappears entirely.
- **Spotlight cannot win**, because the event is suppressed at the tap before macOS hotkey
  handling, and what QEMU finally receives has no Command flag on it at all.
- **It degrades cleanly**: no Accessibility means the bridge refuses to start with a message,
  rather than QEMU booting with a silently dead tap (§2, §7 false trail 1).

The cost is a real host-side daemon that has to track chord state, release held keys on
focus loss (`releaseAll`), and notice QEMU dying — most of those 691 lines are that
bookkeeping, not the trick itself.

### The other thing they have that we do not

Their Accessibility grant belongs to a **signed `.app` bundle** (`dev.tryomarchy.native`),
which is a stable TCC identity — they even ship `AccessibilityPermissionRepair.swift` to
reset stale entries for it. Ours is a bare CLI binary whose grant is attributed to whatever
started the process tree, which §7 measured to be `herdr`, not Ghostty, when `run-vm.sh` is
launched by the agent. **That remains the untested variable**: launching `run-vm.sh` from a
plain Ghostty tab puts the granted app back at the root of the tree.

## 9. Interim conclusion: Command forwarding works, but Spotlight still wins

Measured 2026-08-31, with `run-vm.sh` launched from a **plain Ghostty tab** (the granted app
at the root of the tree) and the grab confirmed on via the window title.

| Test | Result |
|---|---|
| `Could not create event tap` warning | absent — the tap was created |
| Cmd+Space | **Spotlight** |
| Cmd+Return | **Ghostty opens in the guest** |

Cmd+Return is the one that separates the layers, and the reading is not the obvious one.
**It does not exercise the tap at all.** Nothing on macOS claims Cmd+Return, so it arrives
by the ordinary AppKit route and is forwarded by the `NSEventTypeKeyDown` branch because
`isMouseGrabbed` is true — it would work identically with `full-grab=off`. So:

- **Command → Super forwarding works.** The whole Omarchy keymap is fine for every chord
  macOS does not itself claim.
- **The `full-grab` tap is doing nothing observable.** It is the only mechanism that can
  outrank a system hotkey, and Spotlight still wins. Whether it is dead or merely outranked
  was not distinguished; two candidate causes, neither confirmed: a HID tap may simply sit
  below the WindowServer's symbolic-hotkey handling, and macOS silently disables a tap whose
  callback overruns its timeout — `handleTapEvent` takes the BQL and never handles
  `kCGEventTapDisabledByTimeout`, so a tap disabled once stays dead with nothing printed.
  This is very likely why try-omarchy built §8's bridge rather than trusting the `full-grab`
  they already pass.

### The cheap fix, and why it is enough

Because forwarding works, the *only* broken keys are those macOS claims at system level.
Against `home/chime/hyprland.nix`'s actual binds, that is a list of two:

| Guest bind | Host combo | Claimed by macOS? |
|---|---|---|
| `Super+Space` launcher | Cmd+Space | **yes — Spotlight** |
| `Super+Shift+Q` quit Hyprland | Cmd+Shift+Q | **yes — Log Out** |
| `Super+Return/B/L/W/F/V`, `Super+1..9`, `Super+←↑↓→` | Cmd+… | no — app-level, forwarded fine |

So freeing Cmd+Space in **System Settings → Keyboard → Keyboard Shortcuts → Spotlight**
(uncheck *Show Spotlight search*, or reassign it to Option+Space and keep Spotlight) makes
the launcher work with no code and no daemon. The hotkey was at its system default here;
`defaults read com.apple.symbolichotkeys` showed no entry for 64 or 65.

**Warning worth carrying**: `Super+Shift+Q` in the guest is Cmd+Shift+Q on the host, which
is macOS's Log Out. With the tap not capturing, that reaches macOS. Rebinding the guest's
quit action is cheaper than relying on the confirmation dialog.

### When the bridge would still be worth building

§8's bridge remains the only way to get *every* system chord, and its core primitive is
already proven on our QEMU: QMP `input-send-event` holding `meta_l` down across a `spc`
down/up opens walker (verified against a screenshot, 2026-08-31). If the two-key list above
ever grows, that is the design to port.

## 10. Correction: the session bridge loses; focus-gated HID capture was the next test

Measured 2026-09-04 with `scripts/cmd-super-bridge.py` running and its verbose log open. A
human pressed Cmd+Space with the pointer inside the Bento window. Spotlight opened. The
bridge logged Command down and Command up, but **no Space event**, so §8's claim that the
session tap gets the chord before macOS hotkey handling is false on this host.

The mistaken conclusion came from finding `FocusedCommandSuperBridge.swift` in Try
Omarchy and assuming its CLI entry point meant the runtime launched it. Re-reading current
Try Omarchy (`omacom/try-omarchy`, commit `5d0edf6`) showed no invocation of
`--bridge-command-super`. Its real runtime fix is
`macos/patches/qemu-cocoa-full-grab-focus.patch`, which keeps QEMU's existing **HID-level**
tap and changes only its gate:

```objc
-if ([view isMouseGrabbed] && [view handleEvent:event]) {
+if ([view isKeyboardCaptured] && [view handleEvent:event]) {

+- (BOOL) isKeyboardCaptured
+{
+    return isMouseGrabbed ||
+           (full_grab_enabled && [[self window] isKeyWindow]);
+}
```

That distinction matters for two independent reasons:

- Apple defines the HID tap as the point where hardware events enter WindowServer; the
  session tap is later, where events enter a login session. Spotlight can win before the
  latter observes Space.
- QEMU's `notifyMouseModeChange` calls `ungrabMouse` when the guest's absolute tablet driver
  binds. Keyboard ownership tied to `isMouseGrabbed` therefore disappears during a normal
  boot even though the QEMU window remains focused. Cursor position is the wrong lifetime.

Bento now carries the same focused-window invariant, adapted to QEMU 10.1.2, as
`scripts/patches/qemu-10.1-macos-full-grab-focus.patch`. `scripts/build-qemu-gl.sh` applies
and checksums it after the VirGL patch. The standalone Python bridge was removed from the
launch path: it was both too late for Spotlight and redundant once QEMU owns the shortcut
at the HID entry point.

The clean rebuild completed successfully on 2026-09-04. The new binary contains the
`isKeyboardCaptured` selector, retains `virtio-gpu-gl-pci`, and retains its HVF entitlement.

## 11. Final diagnosis: Bento's launch was denied permission; the patch was not disproved

The human acceptance test after restarting onto the rebuilt Bento binary opened Spotlight.
That result was initially misread as evidence that macOS outranked the HID tap. The user's
correction and a comparison with the current Try Omarchy README exposed the missing control:
**whether Accessibility was actually effective for each launch**.

The macOS TCC log makes the comparison decisive:

| Launch / TCC service | Result |
|---|---|
| Bento QEMU, responsible app Ghostty — `kTCCServiceListenEvent` | `authValue=0` — denied |
| Bento QEMU / Ghostty — `kTCCServicePostEvent` | `authValue=2` — allowed |
| Try Omarchy helper — `kTCCServiceListenEvent` | `authValue=2` — allowed |
| Try Omarchy helper — `kTCCServiceAccessibility` | `authValue=2` — allowed |
| Try Omarchy QEMU — `ListenEvent` and `PostEvent` | both `authValue=2` — allowed |

So Bento's tap could be created, and therefore print no QEMU warning, while macOS still
refused to deliver keyboard events to it. Try Omarchy's stable signed app identity had both
permissions. The failed tests prove only the denied launch path, not that a permitted HID
tap loses to Spotlight.

The focus patch remains required. It separates keyboard ownership from the absolute
tablet's mouse-grab lifetime; with the launching app permitted, the HID tap can consume
Cmd+Space while the QEMU window is focused and deliver it as guest Super+Space. For Bento's
current CLI launch, the responsible application is Ghostty. Grant Ghostty Accessibility;
if TCC still reports `ListenEvent` denied, also enable Ghostty under **Privacy & Security →
Input Monitoring**. Fully quit and reopen Ghostty afterward because the new decision must
apply to a fresh process tree.

Cmd+K remains useful as a no-conflict fallback and matches Omarchy's keybinding cheat sheet.
Bento's `bento-keybindings` opens a searchable, view-only list through Walker's dmenu mode,
and Hyprland binds it to Super+K. It was applied live as NixOS generation 42: the live bind
table reported Super+K pointing at the installed helper with no config errors, and an
injected guest Super+K opened the themed list (`artifacts/screen-20260904-212530.png`).

The intended contract is therefore:

| Host chord | Result |
|---|---|
| Cmd+Space, permission effective, Bento focused | guest launcher (Super+Space) |
| Cmd+Space, permission unavailable | macOS Spotlight |
| Cmd+K while Bento is focused | Bento keybinding cheat sheet |
| Other unreserved Cmd chords | corresponding Bento Super binding |

## 12. Superseded experiment: Bento.app made the permission boundary narrow

Implemented 2026-09-05. `scripts/build-macos-app.sh` now builds a small native
`Bento.app` with bundle identifier `dev.bento.vm`. The app contains neither QEMU nor the VM
disk: its only resource is the absolute path of the checkout it was built from. It launches
`scripts/run-vm.sh` and deliberately stays alive until QEMU exits.

Staying alive is the security-relevant part. It keeps Bento.app at the root of QEMU's
process tree, so the event tap's TCC responsibility resolves to Bento instead of whichever
terminal happened to run a shell command. First launch checks `AXIsProcessTrusted`, asks
macOS to register Bento when needed, and opens the Accessibility pane. The VM starts only
on a later launch after that decision is effective.

The build is ad-hoc signed by default and supports a Developer ID identity through
`--sign-identity`. Replacing an ad-hoc build can invalidate its TCC code requirement, so
`--install` refuses to overwrite an installed copy. Ordinary guest rebuilds and changes to
`run-vm.sh` do not change the app binary or its grant.

The CLI path remains valid for headless and development use, but a windowed VM launched
that way still assigns keyboard-capture responsibility to its terminal. The normal
interactive path is now `/Applications/Bento.app`; Ghostty needs no Accessibility grant.

The installed app was granted and relaunched on 2026-09-05. The fresh process tree was
`BentoLauncher(36803) → qemu-system-aarch64(36804)`, and TCC named `dev.bento.vm` at
`/Applications/Bento.app` as QEMU's responsible application. Both of QEMU's relevant
checks were allowed: `kTCCServiceListenEvent authValue=2` and
`kTCCServicePostEvent authValue=2`. That is the exact control which failed under the
Ghostty-owned launch in §11. The remaining acceptance check is the physical Cmd+Space
keystroke, which cannot be synthesized meaningfully from the process that owns the tap.

## 13. Final diagnosis: the HID tap never receives Space; Carbon does

The physical acceptance check in §12 still opened Spotlight even after Bento had both TCC
grants. To shorten the feedback loop, `macos/CommandSpaceProbe.swift` and
`scripts/build-command-space-probe.sh` reduce the problem to a native window whose only job
is to capture Cmd+Space and append every observation to
`/tmp/bento-command-space-probe.log`.

Three probe variants settled the ordering:

1. An authorised `kCGHIDEventTap` at head insertion saw Command down/up but no Space event;
   Spotlight opened.
2. Dynamically calling the private `CGSSetSymbolicHotKeyEnabled(64, false)` stopped
   Spotlight, but the HID tap still saw no Space. Disabling the consumer does not put the
   event back into that stream.
3. After the same temporary disable, Carbon `RegisterEventHotKey(kVK_Space, cmdKey, ...)`
   received the physical chord with Accessibility denied. The trace repeatedly recorded
   `RESULT captured-command-space-via-carbon`.

So signing and TCC identity were not the determining factors. QEMU upstream's
`full-grab=on` event tap cannot implement this particular shortcut on this host, and Try
Omarchy's current focus patch does not change that—it only changes the condition under
which QEMU handles events it actually receives.

Bento's third QEMU patch,
`scripts/patches/qemu-10.1-macos-command-space-carbon.patch`, ports the successful probe:

- only while the QEMU window is key and `full-grab=on`, remember whether Spotlight hotkey
  64 was enabled and temporarily disable it;
- register Cmd+Space with Carbon and inject `meta_l` + `spc` into QEMU's keyboard state,
  holding the chord for QEMU's standard 100 ms `sendkey` interval so the guest input
  device cannot collapse the press and release into one batch;
- unregister it and restore Spotlight on focus loss, AppKit termination, and normal process
  exit;
- degrade to ordinary QEMU behavior with an explicit warning if the private symbolic-hotkey
  functions disappear on a future macOS release; and
- write `Bento Command-Space capture enabled` and each
  `Bento forwarded Command-Space to the guest` to `artifacts/bento-app.log`.

The launcher no longer imports ApplicationServices, checks `AXIsProcessTrusted`, opens
System Settings, or delays VM startup. Bento.app still supplies a convenient stable launch
surface and embeds the tested QEMU, but it requires no Accessibility or Input Monitoring
grant for Cmd+Space. The existing CGEventTap remains best-effort for other system chords;
its permission warning is independent of the dedicated Carbon route.

One operational caveat follows from the private API: a hard kill or crash that bypasses
all cleanup handlers can leave Spotlight hotkey 64 disabled for the login session. Normal
shutdown and focus changes restore it. Logging out also resets that transient WindowServer
state.

The installed build passed the physical end-to-end test on 2026-09-05. For the same key
press, `artifacts/bento-app.log` recorded `Bento forwarded Command-Space to the guest`, a
reader attached to `/dev/input/event1` observed `KEY_LEFTMETA` (125) and `KEY_SPACE` (57)
down/up events, and `artifacts/screen-20260905-025306.png` showed Walker open. A comparison
QMP `sendkey meta_l-spc` produced the same Linux event sequence. This is the acceptance
check missing from §12.

Focus cleanup was verified separately: opening the probe forced Bento to resign key, and
the probe's next launch recorded `SYMBOLIC-HOTKEY initial id=64 enabled=1` before making
its own temporary change. In other words, Bento had already restored Spotlight before the
second process inspected it.
