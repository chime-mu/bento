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
# Requires python3 (macOS ships one) — the QMP protocol is line-delimited JSON over a unix
# socket, and it needs a capabilities handshake before it accepts a command.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="${REPO_ROOT}/artifacts"
QMP_SOCK="${ARTIFACTS}/qmp.sock"

# Each entry is "key:<qemu keyname>" or "type:<literal string>", kept in one list so the
# two interleave in the order the caller wrote them.
INPUT=()
DELAY="0.5"
OUT=""
MODE="auto"
SSH_PORT="2222"
VM_USER="chime"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) INPUT+=("key:${2:?--key needs an argument, e.g. meta_l-ret}"); shift 2 ;;
    --type) INPUT+=("type:${2?--type needs a string}"); shift 2 ;;
    --delay) DELAY="${2:?--delay needs seconds}"; shift 2 ;;
    --guest) MODE="guest"; shift ;;
    --scanout) MODE="scanout"; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown argument: $1" >&2; exit 2 ;;
    *) OUT="$1"; shift ;;
  esac
done

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

# Which capture path? Ask the running QEMU what GPU it was given. `ps` rather than
# `pgrep -f`, whose pattern would also match this script's own command line — the mistake
# learned/phase-3.md §7 and phase-4.md §7 each record once.
#
# Two traps in one line, and both fail the same silent way — always answering "scanout",
# whose symptom is the black screenshot this check exists to prevent:
#
#   1. `-ww` is load-bearing. macOS ps truncates each line to the terminal width, and
#      `-device virtio-gpu-gl-pci` sits ~250 characters into run-vm.sh's command line.
#   2. The match is a bash pattern, not `| grep -q`. Under `set -o pipefail` a *successful*
#      `grep -q` is what breaks it: grep exits at the first match, ps gets SIGPIPE and
#      dies, and pipefail then reports the pipeline as failed. Finding what you were
#      looking for makes the test say no.
if [[ ${MODE} == "auto" ]]; then
  qemu_cmdlines="$(ps -Awwo command= || true)"
  if [[ ${qemu_cmdlines} == *virtio-gpu-gl* ]]; then
    MODE="guest"
  else
    MODE="scanout"
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
  ssh_opts=(-p "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
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
