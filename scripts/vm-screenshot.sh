#!/usr/bin/env bash
# bento — capture what the VM is putting on its screen, from the host.
#
#   ./scripts/vm-screenshot.sh                       # -> artifacts/screen-<timestamp>.png
#   ./scripts/vm-screenshot.sh /tmp/shot.png
#   ./scripts/vm-screenshot.sh --key meta_l-ret      # press a key first, then capture
#   ./scripts/vm-screenshot.sh --key ctrl-alt-f2 --delay 2 out.png
#   ./scripts/vm-screenshot.sh --type 'ls -la' --key ret   # type a string, then press enter
#
# This reads QEMU's own scanout over the QMP socket that run-vm.sh opens, so it works with
# `--headless` and with no window on screen at all — which is the point. It is the outermost
# possible check: not "does the compositor think it drew something", but "what would a human
# looking at the QEMU window see".
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) INPUT+=("key:${2:?--key needs an argument, e.g. meta_l-ret}"); shift 2 ;;
    --type) INPUT+=("type:${2?--type needs a string}"); shift 2 ;;
    --delay) DELAY="${2:?--delay needs seconds}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

python3 - "${QMP_SOCK}" "${OUT}" "${DELAY}" "${INPUT[@]}" <<'PY'
import json, socket, sys, time

sock_path, out_path, delay = sys.argv[1], sys.argv[2], float(sys.argv[3])
inputs = sys.argv[4:]

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

# QEMU 7.1+ accepts format=png; without it the output is a PPM whatever the extension says.
command("screendump", filename=out_path, format="png")
print(out_path)
PY
