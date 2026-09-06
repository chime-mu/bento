#!/usr/bin/env bash
# bento — capture what the VM is putting on its screen, from the host.
#
#   ./scripts/vm-screenshot.sh                       # -> artifacts/screen-<timestamp>.png
#   ./scripts/vm-screenshot.sh /tmp/shot.png
#   ./scripts/vm-screenshot.sh --key meta_l-ret      # press a key first, then capture
#   ./scripts/vm-screenshot.sh --key ctrl-alt-f2 --delay 2 out.png
#   ./scripts/vm-screenshot.sh --type 'ls -la' --key ret   # type a string, then press enter
#   ./scripts/vm-screenshot.sh --scanout             # force the QMP path (see below)
#   ./scripts/vm-screenshot.sh --guest               # force the grim path
#   ./scripts/vm-screenshot.sh --type 'x' --raw-keys   # skip the layout guard (see below)
#
# There are two ways to photograph this machine, and which one is correct depends on how
# the VM was launched. **The default picks for you**; both `--key` and `--type` work either
# way, because input always goes through QEMU's emulated USB keyboard over QMP.
#
#   scanout  QMP `screendump` writes QEMU's own scanout to a PNG. The outermost possible
#            check — not "does the compositor believe it drew something" but "what would a
#            human looking at the QEMU window see" — and it works under `--headless`, with
#            no window on screen at all.
#
#   guest    `grim` inside the guest, over ssh. One layer further in: it asks the
#            compositor for its output rather than reading the framebuffer.
#
# **Under `run-vm.sh --gl`, `screendump` silently returns an all-black PNG** and the guest
# path is the only one that works. That is not a bug we can fix from here: `qmp_screendump`
# in ui/ui-qmp-cmds.c copies `surface->image`, the pixman DisplaySurface, and with
# virtio-gpu-gl the guest's scanout is a GL texture that goes straight to Cocoa — the
# pixman surface it reads is real, allocated, and blank. It does not error; it hands back a
# perfectly valid picture of nothing (learned/phase-6.md §3).
#
# So the mode is chosen by looking at what QEMU was actually started with, rather than by
# trusting a flag or noticing afterwards that the picture came out dark.
#
# `--key` sends a keystroke through the emulated USB keyboard (QEMU `sendkey` syntax:
# `meta_l-ret`, `ctrl-alt-f2`, `a`), which is the only way to exercise a compositor
# keybinding without a hand on the keyboard. Modifier names are QEMU's, not X11's: the
# Super key is `meta_l`. `--type` sends a whole ASCII string a character at a time, which
# is how you drive a program *inside* the guest's terminal rather than the compositor
# around it. Both may be repeated, and they are sent in the order written.
#
# `--type` needs one more thing to be true, and since the guest stopped being US it is not
# free: `sendkey` injects physical key *positions*, so the string is only typed as written
# if the guest reads those positions as US. Under `dkmac` it does not. So --type asks the
# guest for its layout over ssh, forces `us` for the duration, and restores it afterwards
# — which means --type now needs a reachable ssh and a running compositor, and fails loudly
# rather than typing the wrong thing. `--raw-keys` skips all of that, for a target that is
# genuinely US already: the tty1 greeter, for one, since `console.keyMap` is unset.
#
# Requires python3 (macOS ships one) — the QMP protocol is line-delimited JSON over a unix
# socket, and it needs a capabilities handshake before it accepts a command.

set -euo pipefail
umask 077

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="${BENTO_ARTIFACTS:-${REPO_ROOT}/artifacts}"
RUNTIME_DESCRIPTOR="${ARTIFACTS}/runtime.json"
QMP_SOCK=""

# Each entry is "key:<qemu keyname>" or "type:<literal string>", kept in one list so the
# two interleave in the order the caller wrote them.
INPUT=()
DELAY="0.5"
OUT=""
MODE="auto"
SSH_PORT="2222"
VM_USER="chime"
GPU_MODE=""
# See the "--type types positions, not characters" block below. 1 disables the guard.
RAW_KEYS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) INPUT+=("key:${2:?--key needs an argument, e.g. meta_l-ret}"); shift 2 ;;
    --type) INPUT+=("type:${2?--type needs a string}"); shift 2 ;;
    --delay) DELAY="${2:?--delay needs seconds}"; shift 2 ;;
    --guest) MODE="guest"; shift ;;
    --scanout) MODE="scanout"; shift ;;
    --raw-keys) RAW_KEYS=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown argument: $1" >&2; exit 2 ;;
    *) OUT="$1"; shift ;;
  esac
done

if [[ ! -f ${RUNTIME_DESCRIPTOR} || -L ${RUNTIME_DESCRIPTOR} ]]; then
  echo "error: no private runtime descriptor at ${RUNTIME_DESCRIPTOR} — is the VM running?" >&2
  echo "       start it with:  ./scripts/run-vm.sh [--headless]" >&2
  exit 1
fi

runtime_fields="$(/usr/bin/python3 - "${RUNTIME_DESCRIPTOR}" <<'PY'
import json
import os
import stat
import sys

path = sys.argv[1]
info = os.stat(path, follow_symlinks=False)
if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
    raise SystemExit("runtime descriptor has unsafe ownership or permissions")
with open(path, encoding="utf-8") as stream:
    value = json.load(stream)
if value.get("version") != 1:
    raise SystemExit("unsupported runtime descriptor version")
qmp = value.get("qmp")
pid = value.get("pid")
port = value.get("sshPort")
gpu = value.get("gpu")
if (not isinstance(qmp, str) or not os.path.isabs(qmp)
        or not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0
        or not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535):
    raise SystemExit("invalid runtime descriptor")
if gpu not in ("virgl", "software"):
    raise SystemExit("invalid GPU mode in runtime descriptor")
print(f"{qmp}\t{pid}\t{port}\t{gpu}")
PY
)" || {
  echo "error: could not read ${RUNTIME_DESCRIPTOR}" >&2
  exit 1
}
IFS=$'\t' read -r QMP_SOCK QEMU_PID SSH_PORT GPU_MODE <<< "${runtime_fields}"
if [[ ! ${QEMU_PID} =~ ^[0-9]+$ ]] || ! kill -0 "${QEMU_PID}" 2>/dev/null; then
  echo "error: Bento's runtime descriptor is stale" >&2
  exit 1
fi
if [[ ! -S ${QMP_SOCK} ]]; then
  echo "error: no QMP socket at ${QMP_SOCK} — is the VM running?" >&2
  echo "       start it with:  ./scripts/run-vm.sh [--headless]" >&2
  exit 1
fi

if [[ -z ${OUT} ]]; then
  OUT="${ARTIFACTS}/screen-$(date +%Y%m%d-%H%M%S).png"
fi
# QEMU writes the file itself, as its own process — a relative path would land in whatever
# directory the VM was started from rather than this one.
case "${OUT}" in
  /*) ;;
  *) OUT="$(pwd)/${OUT}" ;;
esac

# The launcher records the selected GPU mode alongside QMP and SSH coordinates. This is
# exact and avoids inspecting every process command line on the host.
if [[ ${MODE} == "auto" ]]; then
  if [[ ${GPU_MODE} == "virgl" ]]; then
    MODE="guest"
  else
    MODE="scanout"
  fi
fi

# `sendkey` injects *physical key positions*, and keys_for() below spells those positions
# out on the assumption that the guest reads them as US. Since learned/keyboard-layout.md
# the guest runs `dkmac`, where the same positions mean different things — the `minus`
# position types `+`, the `slash` position types `-` — so a --type string silently types
# something other than what it says. Every graphical test since Phase 3 goes through here.
#
# Teaching this script the guest's layout would be a second copy of what already lives in
# modules/xkb/dkmac, and would rot the moment a key moves. Instead: force the guest to US
# for the duration and put back exactly what was there. The restore is a trap, so it runs
# on a failed screendump and on Ctrl-C as well as on success.
#
# `--key` needs none of this — modifiers and ret/tab/spc are position-stable across
# layouts. Only --type's ASCII is affected, so only --type pays for the ssh round trip.
ssh_opts=(-p "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# hyprctl over ssh needs the compositor's socket, and an ssh session has neither
# XDG_RUNTIME_DIR nor WAYLAND_DISPLAY — same lookup the grim path does further down.
guest_hyprctl() {
  ssh "${ssh_opts[@]}" "${VM_USER}@localhost" "
        export XDG_RUNTIME_DIR=/run/user/1000
        WAYLAND_DISPLAY=\$(cd \"\$XDG_RUNTIME_DIR\" && ls -1 | grep -m1 '^wayland-[0-9]\\+\$')
        [ -n \"\$WAYLAND_DISPLAY\" ] || { echo 'no wayland socket in '\"\$XDG_RUNTIME_DIR\" >&2; exit 1; }
        export WAYLAND_DISPLAY
        exec hyprctl $*"
}

# `eval`, not `keyword`: the guest's Hyprland is configured in Lua (home/chime/hyprland.nix),
# and under the Lua config manager `hyprctl keyword` refuses with "keyword can't work with
# non-legacy parsers. Use eval." Reading is unaffected — `getoption` still answers `str: …`
# in both. The Lua goes over in single quotes because `guest_hyprctl` interpolates into a
# remote shell command, where the parentheses would otherwise be syntax.
set_guest_layout() {
  guest_hyprctl "eval 'hl.config({ input = { kb_layout = \"$1\" } })'"
}

SAVED_LAYOUT=""
restore_layout() {
  [[ -n ${SAVED_LAYOUT} ]] || return 0
  # Set the name back rather than `hyprctl reload`: reload would also discard any *other*
  # runtime setting a caller had applied, which is not this function's business to undo.
  set_guest_layout "${SAVED_LAYOUT}" >/dev/null 2>&1 || true
  SAVED_LAYOUT=""
}

typing=0
for item in ${INPUT[@]+"${INPUT[@]}"}; do
  case "${item}" in type:*) typing=1 ;; esac
done

if [[ ${typing} -eq 1 && ${RAW_KEYS} -eq 0 ]]; then
  # `str: dkmac` on the first line; empty if the option was never set.
  SAVED_LAYOUT="$(guest_hyprctl "getoption input:kb_layout" 2>/dev/null | awk '/^str:/{print $2; exit}')" || true
  if [[ -z ${SAVED_LAYOUT} ]]; then
    echo "error: --type could not read the guest's keyboard layout over ssh." >&2
    echo "       Without it the typed string is positions, not characters: under a" >&2
    echo "       non-US layout it types something else entirely, and nothing fails." >&2
    echo "       Fix the ssh path, or pass --raw-keys if the target really is US" >&2
    echo "       (the tty1 greeter is, for example — console.keyMap is unset)." >&2
    exit 1
  fi
  if [[ ${SAVED_LAYOUT} != "us" ]]; then
    trap restore_layout EXIT INT TERM
    set_guest_layout us >/dev/null
  else
    SAVED_LAYOUT=""   # already US; nothing to put back
  fi
fi
# `${INPUT[@]+...}` because macOS ships bash 3.2, where an empty array expanded under
# `set -u` is an "unbound variable" — a plain capture with no --key/--type would die here.
python3 - "${QMP_SOCK}" "${OUT}" "${DELAY}" "${MODE}" ${INPUT[@]+"${INPUT[@]}"} <<'PY'
import json, socket, sys, time

sock_path, out_path, delay, mode = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
inputs = sys.argv[5:]

# QEMU's `sendkey` takes key *names*, so an ASCII string has to be spelled out one keyname
# at a time, with `shift-` in front of anything that needs it on a US layout.
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
    "(": "9", ")": "0", "_": "minus", "+": "equal", "{": "bracket_left",
    "}": "bracket_right", "|": "backslash", ":": "semicolon", '"': "apostrophe",
    "<": "comma", ">": "dot", "?": "slash", "~": "grave_accent",
}
PLAIN = {
    " ": "spc", "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
    "\\": "backslash", ";": "semicolon", "'": "apostrophe", ",": "comma", ".": "dot",
    "/": "slash", "`": "grave_accent", "\n": "ret", "\t": "tab",
}

def keys_for(text):
    for ch in text:
        if ch.isupper():
            yield "shift-" + ch.lower()
        elif ch in SHIFTED:
            yield "shift-" + SHIFTED[ch]
        elif ch in PLAIN:
            yield PLAIN[ch]
        elif ch.isalnum():
            yield ch
        else:
            raise SystemExit(f"vm-screenshot: no key name for {ch!r}")

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sock_path)
f = s.makefile("rw", encoding="utf-8", newline="\n")

def command(cmd, **args):
    """Send one QMP command and return its result, skipping asynchronous events."""
    f.write(json.dumps({"execute": cmd, "arguments": args} if args else {"execute": cmd}) + "\n")
    f.flush()
    while True:
        reply = json.loads(f.readline())
        if "event" in reply:          # events interleave with replies; they are not ours
            continue
        if "error" in reply:
            raise SystemExit(f"qmp: {cmd} failed: {reply['error']['desc']}")
        return reply.get("return")

json.loads(f.readline())              # the greeting banner
command("qmp_capabilities")           # nothing else is accepted until this is negotiated

def sendkey(name):
    # `sendkey` is a human-monitor command; QMP's own input-send-event wants keycodes
    # rather than the friendly `meta_l-ret` spelling, so go through the monitor.
    command("human-monitor-command", **{"command-line": f"sendkey {name}"})

for item in inputs:
    kind, _, value = item.partition(":")
    if kind == "key":
        sendkey(value)
    else:
        for name in keys_for(value):
            sendkey(name)
            # The guest's key repeat/debounce is real hardware timing as far as it knows;
            # firing a whole string with no gap drops characters.
            time.sleep(0.05)
    time.sleep(delay)

# In guest mode the keystrokes above were the whole job; grim takes the picture, back in
# the shell. QEMU 7.1+ accepts format=png; without it the output is a PPM whatever the
# extension says.
if mode == "scanout":
    command("screendump", filename=out_path, format="png")
PY

if [[ ${MODE} == "guest" ]]; then
  # grim needs to find the compositor, and an ssh session has neither XDG_RUNTIME_DIR nor
  # WAYLAND_DISPLAY. The socket name is *not* reliably wayland-1 — it is whichever number
  # the compositor got — so it is looked up rather than assumed. `grim -` writes the PNG
  # to stdout, which saves a temp file in the guest and a second hop to fetch it.
  if ! ssh "${ssh_opts[@]}" "${VM_USER}@localhost" '
        export XDG_RUNTIME_DIR=/run/user/1000
        WAYLAND_DISPLAY=$(cd "$XDG_RUNTIME_DIR" && ls -1 | grep -m1 "^wayland-[0-9]\+$")
        [ -n "$WAYLAND_DISPLAY" ] || { echo "no wayland socket in $XDG_RUNTIME_DIR" >&2; exit 1; }
        export WAYLAND_DISPLAY
        exec grim -' > "${OUT}"; then
    rm -f "${OUT}"
    echo "error: grim failed in the guest." >&2
    echo "       Is the desktop up? Is grim installed (modules/desktop.nix)?" >&2
    echo "       The scanout path is not a fallback here — under --gl it returns black." >&2
    exit 1
  fi
fi

echo "${OUT}"
