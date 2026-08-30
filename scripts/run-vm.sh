#!/usr/bin/env bash
# bento — boot artifacts/bento.qcow2 in QEMU on the Apple Silicon host.
#
#   ./scripts/run-vm.sh                # Cocoa window + serial console on this terminal
#   ./scripts/run-vm.sh --headless     # no window; serial console only (what agents use)
#   ./scripts/run-vm.sh --no-gl        # force software rendering (stock Homebrew QEMU)
#   ./scripts/run-vm.sh --no-grab      # let macOS keep Cmd+Space and the other system combos
#   ./scripts/run-vm.sh --reset-vars   # throw away the EFI variable store first
#   ./scripts/run-vm.sh --memory 4G --cpus 2
#
# VirGL is used automatically when ./scripts/build-qemu-gl.sh has been run; `--gl` demands
# it (and fails if it is not built), `--no-gl` refuses it. The banner says which you got.
#
# Once up:  ssh -p 2222 chime@localhost
# To quit:  `poweroff` in the guest, or Ctrl-A X at the serial console.
#
# The window captures system key combinations, so Cmd+Space opens the guest's launcher
# instead of Spotlight. That is `full-grab=on`, and it is worth knowing what it does before
# it surprises you — all of the following is from ui/cocoa.m in the QEMU we build:
#
#   * The Mac's Command key is what reaches the guest as Super. Cocoa maps it that way by
#     default (`swap_opt_cmd` is false), so Omarchy's Super+X scheme is Cmd+X here.
#   * Command is only forwarded while the *mouse* is grabbed, and with usb-tablet that
#     happens the moment the pointer enters the window (`mouseEntered:` -> `grabMouse`).
#     Ctrl+Alt+G releases it, and so does clicking away — the window title says which.
#   * `full-grab=on` adds a CGEventTap at the head of kCGHIDEventTap, ahead of macOS's own
#     hotkey handling, and swallows the event when the mouse is grabbed. So Spotlight,
#     Cmd+Tab and Cmd+Q go to the guest while you are in the window, and to macOS when you
#     are not. Nothing is captured while another app has focus.
#   * It needs Accessibility permission, granted to the *terminal application this script
#     runs from* rather than to qemu — a CLI binary is attributed to whatever launched it.
#     If it is missing, CGEventTapCreate returns NULL and QEMU prints one line:
#     "Could not create event tap, system key combos will not be captured." It then runs
#     perfectly normally, minus the grab, which is the one failure worth watching for.
#     System Settings -> Privacy & Security -> Accessibility.
#
# `--no-grab` turns it off. None of this touches vm-screenshot.sh: QMP `sendkey meta_l-spc`
# is injected into the emulated keyboard and never goes near the host's.
#
# Two host quirks, both measured in Phase 0 (learned/phase-0.md §2):
#
#   1. Homebrew ships edk2-aarch64-code.fd but NO edk2-aarch64-vars.fd — only a 32-bit
#      edk2-arm-vars.fd, which is the wrong architecture. So we fabricate the writable
#      variable store ourselves. Both pflash drives must be 64 MiB or EDK2 won't boot.
#   2. The *Homebrew* QEMU has no OpenGL compiled in: virtio-gpu-gl-pci does not exist
#      and `-display cocoa,gl=es` errors out. Plain virtio-gpu-pci is the only option
#      there, and the guest renders in software (llvmpipe).
#
# So Phase 6 built a second QEMU — a patched 10.1.2 linked against virglrenderer and
# ANGLE, installed by ./scripts/build-qemu-gl.sh under ~/.local/state/bento/qemu-gl. When
# it is present it is used by default, because hosts/bento-vm/default.nix now assumes a
# GPU. The stock Homebrew binary is never touched or replaced: it stays on PATH as the
# `--no-gl` fallback, so a broken GL build can cost us performance but never a bootable
# VM. See learned/phase-6.md.
#
# `--headless` drops the *window*, not the GPU. Phase 3 puts Hyprland on this machine, and
# a compositor needs a DRM device to bind: with no virtio-gpu at all the guest has no
# /dev/dri/card0 and the graphical session cannot start, which would make the headless mode
# useless for exactly the phase that needs it most. QEMU renders the scanout into memory
# whether or not anyone is looking at it — and `screendump` over QMP can then read it back,
# so an agent with no screen can still see what the display shows (learned/phase-3.md §1).
#
# `--headless` implies software rendering, and that is not a limitation worth removing:
# virtio-gpu-gl needs a display backend to get a GL context from, and `-display none` has
# none. It is also the *useful* pairing, because under GL a QMP screendump comes back
# black — the scanout is a GL texture by then and screendump only knows about the pixman
# surface (learned/phase-6.md §3). Headless is how you photograph a boot failure.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="${REPO_ROOT}/artifacts"
DISK="${ARTIFACTS}/bento.qcow2"
VARS="${ARTIFACTS}/edk2-aarch64-vars.fd"
CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
QMP_SOCK="${ARTIFACTS}/qmp.sock"

# virtio-gpu's own default is 1280x800, and with edid=on (the default) that is what the
# guest's EDID advertises and what Hyprland picks as the preferred mode. 1080p is a
# friendlier desktop; there is no cost, since nothing is being scanned out by hardware.
GPU_XRES="1920"
GPU_YRES="1080"

MEMORY="8G"
CPUS="4"
SSH_PORT="2222"
HEADLESS=0
RESET_VARS=0
# Capture system key combos so Super+X reaches Hyprland instead of macOS. Default on: the
# guest is a desktop whose whole keymap hangs off Super, and Cmd+Space is Spotlight's.
GRAB=1
# auto: use the GL build if it has been built, the Homebrew one otherwise. The guest
# config (hosts/bento-vm/default.nix) assumes GL, so defaulting to it keeps the machine
# running in the mode it was built for; `--no-gl` is the escape hatch and still works.
GL="auto"
GL_EXPLICIT=0

GL_QEMU="${HOME}/.local/state/bento/qemu-gl/bin/qemu-system-aarch64"
QEMU="qemu-system-aarch64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless) HEADLESS=1; shift ;;
    --gl) GL=1; GL_EXPLICIT=1; shift ;;
    --no-gl|--software) GL=0; GL_EXPLICIT=1; shift ;;
    --no-grab) GRAB=0; shift ;;
    --grab) GRAB=1; shift ;;
    --reset-vars) RESET_VARS=1; shift ;;
    --memory) MEMORY="${2:?--memory needs an argument}"; shift 2 ;;
    --cpus) CPUS="${2:?--cpus needs an argument}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?--ssh-port needs an argument}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f ${DISK} ]]; then
  echo "error: ${DISK} not found — build it first:  ./scripts/build-image.sh" >&2
  exit 1
fi

if [[ ! -f ${CODE} ]]; then
  echo "error: EFI firmware missing: ${CODE}" >&2
  echo "       install it with:  brew install qemu" >&2
  exit 1
fi

if [[ ${RESET_VARS} -eq 1 ]]; then
  rm -f "${VARS}"
fi

if [[ ! -f ${VARS} ]]; then
  echo "==> Creating a blank 64 MiB EFI variable store: ${VARS}"
  mkdir -p "${ARTIFACTS}"
  dd if=/dev/zero of="${VARS}" bs=1m count=64 status=none
fi

if [[ ${GL} == "auto" ]]; then
  if [[ -x ${GL_QEMU} ]]; then GL=1; else GL=0; fi
elif [[ ${GL} -eq 1 && ! -x ${GL_QEMU} ]]; then
  # Explicitly asked for, so this is an error rather than a silent downgrade.
  echo "error: no GL-capable QEMU at ${GL_QEMU}" >&2
  echo "       build it first:  ./scripts/build-qemu-gl.sh" >&2
  exit 1
fi

gpu_device="virtio-gpu-pci,xres=${GPU_XRES},yres=${GPU_YRES}"
cocoa_opts="cocoa"

if [[ ${GL} -eq 1 ]]; then
  QEMU="${GL_QEMU}"
  gpu_device="virtio-gpu-gl-pci,xres=${GPU_XRES},yres=${GPU_YRES}"
  # gl=es, not gl=on: ANGLE implements GL ES over Metal. macOS's own OpenGL stops at
  # 4.1 and virglrenderer wants more than that, which is why ANGLE is in the picture
  # at all (learned/phase-6.md §1).
  cocoa_opts+=",gl=es"
fi

if [[ ${GRAB} -eq 1 ]]; then
  # full-grab is a base-DisplayCocoa option, present in both QEMUs — it needs no patch and
  # no GL. See the header for what it captures and why it can fail quietly.
  cocoa_opts+=",full-grab=on"
fi

display_args=(-display "${cocoa_opts}")

if [[ ${HEADLESS} -eq 1 ]]; then
  # virtio-gpu-gl needs a display backend that can hand it a GL context; `-display none`
  # has none to give. If GL was merely inferred, quietly drop back to the software GPU —
  # `--headless` is what agents use and it must not start failing just because a GL QEMU
  # got built. If it was asked for by name, say so instead of silently doing something else.
  if [[ ${GL} -eq 1 && ${GL_EXPLICIT} -eq 1 ]]; then
    echo "error: --gl and --headless are mutually exclusive" >&2
    echo "       virtio-gpu-gl has no display backend to get a GL context from." >&2
    exit 2
  fi
  GL=0
  QEMU="qemu-system-aarch64"
  gpu_device="virtio-gpu-pci,xres=${GPU_XRES},yres=${GPU_YRES}"
  display_args=(-display none)
fi

# A stale unix socket from a killed VM makes QEMU exit with "Address already in use".
rm -f "${QMP_SOCK}"

echo "==> Booting bento (${CPUS} cpus, ${MEMORY}, ssh on localhost:${SSH_PORT})"
if [[ ${GL} -eq 1 ]]; then
  echo "    VirGL: ${gpu_device%%,*} on $("${QEMU}" --version | head -1)"
else
  echo "    software rendering: ${gpu_device%%,*}"
fi
if [[ ${HEADLESS} -eq 0 ]]; then
  if [[ ${GRAB} -eq 1 ]]; then
    echo "    keyboard: system combos captured — Cmd is Super, Ctrl-Alt-G releases the grab"
    echo "              (a 'Could not create event tap' line below means macOS Accessibility"
    echo "               is not granted to this terminal, and Cmd+Space is still Spotlight)"
  else
    echo "    keyboard: not grabbed — macOS keeps Cmd+Space and the other system combos"
  fi
fi
echo "    serial console follows; Ctrl-A X to kill the VM"
echo "    QMP on ${QMP_SOCK} (screendump, sendkey)"
echo

exec "${QEMU}" \
  -name bento \
  -machine virt,accel=hvf \
  -cpu host \
  -smp "${CPUS}" \
  -m "${MEMORY}" \
  -drive "if=pflash,format=raw,readonly=on,file=${CODE}" \
  -drive "if=pflash,format=raw,file=${VARS}" \
  -drive "if=virtio,format=qcow2,file=${DISK}" \
  -device "${gpu_device}" \
  "${display_args[@]}" \
  -qmp "unix:${QMP_SOCK},server=on,wait=off" \
  -device qemu-xhci \
  -device usb-kbd \
  -device usb-tablet \
  -nic "user,model=virtio-net-pci,hostfwd=tcp::${SSH_PORT}-:22" \
  -serial mon:stdio
