#!/usr/bin/env bash
# bento — boot artifacts/bento.qcow2 in QEMU on the Apple Silicon host.
#
#   ./scripts/run-vm.sh                # Cocoa window + serial console on this terminal
#   ./scripts/run-vm.sh --headless     # no window; serial console only (what agents use)
#   ./scripts/run-vm.sh --reset-vars   # throw away the EFI variable store first
#   ./scripts/run-vm.sh --memory 4G --cpus 2
#
# Once up:  ssh -p 2222 chime@localhost
# To quit:  `poweroff` in the guest, or Ctrl-A X at the serial console.
#
# Two host quirks, both measured in Phase 0 (learned/phase-0.md §2):
#
#   1. Homebrew ships edk2-aarch64-code.fd but NO edk2-aarch64-vars.fd — only a 32-bit
#      edk2-arm-vars.fd, which is the wrong architecture. So we fabricate the writable
#      variable store ourselves. Both pflash drives must be 64 MiB or EDK2 won't boot.
#   2. This QEMU has no OpenGL compiled in: virtio-gpu-gl-pci does not exist and
#      `-display cocoa,gl=es` errors out. Plain virtio-gpu-pci is the only option, and
#      the guest renders in software. That is Phase 6's problem, not a flag we forgot.
#
# `--headless` drops the *window*, not the GPU. Phase 3 puts Hyprland on this machine, and
# a compositor needs a DRM device to bind: with no virtio-gpu at all the guest has no
# /dev/dri/card0 and the graphical session cannot start, which would make the headless mode
# useless for exactly the phase that needs it most. QEMU renders the scanout into memory
# whether or not anyone is looking at it — and `screendump` over QMP can then read it back,
# so an agent with no screen can still see what the display shows (learned/phase-3.md §1).

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless) HEADLESS=1; shift ;;
    --reset-vars) RESET_VARS=1; shift ;;
    --memory) MEMORY="${2:?--memory needs an argument}"; shift 2 ;;
    --cpus) CPUS="${2:?--cpus needs an argument}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?--ssh-port needs an argument}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

display_args=(-display cocoa)
if [[ ${HEADLESS} -eq 1 ]]; then
  display_args=(-display none)
fi

# A stale unix socket from a killed VM makes QEMU exit with "Address already in use".
rm -f "${QMP_SOCK}"

echo "==> Booting bento (${CPUS} cpus, ${MEMORY}, ssh on localhost:${SSH_PORT})"
echo "    serial console follows; Ctrl-A X to kill the VM"
echo "    QMP on ${QMP_SOCK} (screendump, sendkey)"
echo

exec qemu-system-aarch64 \
  -name bento \
  -machine virt,accel=hvf \
  -cpu host \
  -smp "${CPUS}" \
  -m "${MEMORY}" \
  -drive "if=pflash,format=raw,readonly=on,file=${CODE}" \
  -drive "if=pflash,format=raw,file=${VARS}" \
  -drive "if=virtio,format=qcow2,file=${DISK}" \
  -device "virtio-gpu-pci,xres=${GPU_XRES},yres=${GPU_YRES}" \
  "${display_args[@]}" \
  -qmp "unix:${QMP_SOCK},server=on,wait=off" \
  -device qemu-xhci \
  -device usb-kbd \
  -device usb-tablet \
  -nic "user,model=virtio-net-pci,hostfwd=tcp::${SSH_PORT}-:22" \
  -serial mon:stdio
