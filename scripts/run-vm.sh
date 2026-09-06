#!/usr/bin/env bash
# bento — boot artifacts/bento.qcow2 in QEMU on the Apple Silicon host.
#
#   ./scripts/run-vm.sh                         # immersive full screen
#   ./scripts/run-vm.sh --windowed              # resizable Cocoa window
#   ./scripts/run-vm.sh --headless              # no window; serial console only
#   ./scripts/run-vm.sh --no-gl                 # software-rendered display
#   ./scripts/run-vm.sh --audio                 # force host audio (including headless)
#   ./scripts/run-vm.sh --no-audio              # disable speaker and microphone devices
#   ./scripts/run-vm.sh --share /absolute/path  # read/write at ~/Mac in the guest
#   ./scripts/run-vm.sh --no-clipboard          # disable automatic clipboard sharing
#   ./scripts/run-vm.sh --memory 4G --cpus 2 --ssh-port 2222
#
# Clipboard sharing is enabled by default. Folder sharing is disabled by default. Bento's
# patched QEMU is used for graphical, software, and headless launches whenever it exists;
# stock QEMU is only an emergency boot fallback and cannot provide Bento's owner-mapped 9p.

set -euo pipefail
umask 077

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARTIFACTS="${BENTO_ARTIFACTS:-${REPO_ROOT}/artifacts}"
DISK="${ARTIFACTS}/bento.qcow2"
VARS="${ARTIFACTS}/edk2-aarch64-vars.fd"
VARS_PROFILE="${ARTIFACTS}/edk2-aarch64-vars.profile"
CODE="${BENTO_EFI_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
RUNTIME_DESCRIPTOR="${ARTIFACTS}/runtime.json"
RUNTIME_DESCRIPTOR_OWNED=0
VM_LOCK="${ARTIFACTS}/vm.lock"
VM_LOCK_HELD=0
RUNTIME_DIR=""
QEMU_PID=""
BRIDGE_SUPERVISOR_PID=""
BRIDGE_PID_FILE=""

GPU_XRES="1920"
GPU_YRES="1080"
MEMORY="8G"
CPUS="4"
SSH_PORT="2222"
HEADLESS=0
WINDOWED=0
RESET_VARS=0
GRAB=1
GL="auto"
GL_EXPLICIT=0
CLIPBOARD=1
AUDIO=-1
AUDIO_EXPLICIT=0
SHARE_PATH=""

PATCHED_QEMU="${BENTO_QEMU:-${HOME}/.local/state/bento/qemu-gl/bin/qemu-system-aarch64}"
QEMU_DATA="${BENTO_QEMU_DATA:-}"
SOFTWARE_QEMU="${BENTO_SOFTWARE_QEMU:-qemu-system-aarch64}"
CLIPBOARD_BRIDGE="${BENTO_CLIPBOARD_BRIDGE:-${REPO_ROOT}/artifacts/bin/BentoClipboardBridge}"
QEMU="${SOFTWARE_QEMU}"
PATCHED_RUNTIME=0

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless) HEADLESS=1; shift ;;
    --windowed) WINDOWED=1; shift ;;
    --gl) GL=1; GL_EXPLICIT=1; shift ;;
    --no-gl|--software) GL=0; GL_EXPLICIT=1; shift ;;
    --no-grab) GRAB=0; shift ;;
    --grab) GRAB=1; shift ;;
    --reset-vars) RESET_VARS=1; shift ;;
    --clipboard) CLIPBOARD=1; shift ;;
    --no-clipboard) CLIPBOARD=0; shift ;;
    --audio)
      if [[ ${AUDIO_EXPLICIT} -eq 1 && ${AUDIO} -ne 1 ]]; then
        echo "error: --audio and --no-audio are mutually exclusive" >&2
        exit 2
      fi
      AUDIO=1; AUDIO_EXPLICIT=1; shift
      ;;
    --no-audio)
      if [[ ${AUDIO_EXPLICIT} -eq 1 && ${AUDIO} -ne 0 ]]; then
        echo "error: --audio and --no-audio are mutually exclusive" >&2
        exit 2
      fi
      AUDIO=0; AUDIO_EXPLICIT=1; shift
      ;;
    --share) SHARE_PATH="${2:?--share needs an absolute directory}"; shift 2 ;;
    --no-share) SHARE_PATH=""; shift ;;
    --memory) MEMORY="${2:?--memory needs an argument}"; shift 2 ;;
    --cpus) CPUS="${2:?--cpus needs an argument}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?--ssh-port needs an argument}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ${HEADLESS} -eq 1 && ${WINDOWED} -eq 1 ]]; then
  echo "error: --headless and --windowed are mutually exclusive" >&2
  exit 2
fi
if [[ ${AUDIO} -eq -1 ]]; then
  if [[ ${HEADLESS} -eq 1 ]]; then AUDIO=0; else AUDIO=1; fi
fi
if [[ ! ${SSH_PORT} =~ ^[0-9]+$ ]] \
    || (( 10#${SSH_PORT} < 1 || 10#${SSH_PORT} > 65535 )); then
  echo "error: --ssh-port must be an integer from 1 through 65535" >&2
  exit 2
fi
SSH_PORT="$((10#${SSH_PORT}))"

# Resolve once and reject paths QEMU's comma-delimited fsdev syntax cannot represent
# safely. The same policy lives in BentoLauncherCore.swift for the native picker.
validate_share_path() {
  /usr/bin/python3 - "$1" <<'PY'
import os
import stat
import sys
import tempfile

raw = sys.argv[1]
if not os.path.isabs(raw):
    raise SystemExit("the shared folder must be an absolute path")
if "," in raw or any(ord(ch) < 32 or ord(ch) == 127 for ch in raw):
    raise SystemExit("the shared folder path cannot contain commas or control characters")
absolute = os.path.abspath(raw)
canonical = os.path.realpath(raw)
if absolute != canonical:
    raise SystemExit("the shared folder path cannot contain symbolic links")
try:
    info = os.lstat(canonical)
except OSError as error:
    raise SystemExit(f"the shared folder is unavailable: {error.strerror}")
if not stat.S_ISDIR(info.st_mode):
    raise SystemExit("the shared folder must be a directory")
if info.st_uid != os.getuid():
    raise SystemExit("the shared folder must be directly owned by the current user")

home = os.path.realpath(os.path.expanduser("~"))
library = os.path.join(home, "Library")
blocked_trees = [
    "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc",
    "/var", "/dev", "/cores", "/opt", "/private", "/tmp",
    os.path.realpath(tempfile.gettempdir()),
]
if canonical == home:
    raise SystemExit("sharing the whole home directory is not allowed")
if canonical == library or canonical.startswith(library + os.sep):
    raise SystemExit("sharing ~/Library is not allowed")
if canonical == "/" or any(
    canonical == root or canonical.startswith(root + os.sep) for root in blocked_trees
):
    raise SystemExit("system and temporary directories cannot be shared")
if canonical == "/Volumes" or os.path.ismount(canonical):
    raise SystemExit("share a user-owned subdirectory, not a filesystem or volume root")
print(canonical)
PY
}

if [[ -n ${SHARE_PATH} ]]; then
  if ! validated_share="$(validate_share_path "${SHARE_PATH}" 2>&1)"; then
    echo "error: ${validated_share}" >&2
    exit 2
  fi
  SHARE_PATH="${validated_share}"
fi

mkdir -p -- "${ARTIFACTS}"
chmod 0700 "${ARTIFACTS}"
for sensitive in \
  "${DISK}" "${VARS}" "${VARS_PROFILE}" \
  "${ARTIFACTS}/bento-app.log" "${ARTIFACTS}/vm-boot.log" \
  "${ARTIFACTS}/bridge.log" "${RUNTIME_DESCRIPTOR}"; do
  if [[ -e ${sensitive} && ! -L ${sensitive} ]]; then
    chmod 0600 "${sensitive}"
  fi
done
if [[ -d ${VM_LOCK} && ! -L ${VM_LOCK} ]]; then
  chmod 0700 "${VM_LOCK}"
  if [[ -f ${VM_LOCK}/pid && ! -L ${VM_LOCK}/pid ]]; then
    chmod 0600 "${VM_LOCK}/pid"
  fi
fi

if [[ ! -f ${DISK} ]]; then
  echo "error: ${DISK} not found — build it first:  ./scripts/build-image.sh" >&2
  exit 1
fi
if [[ ! -f ${CODE} ]]; then
  echo "error: EFI firmware missing: ${CODE}" >&2
  echo "       install it with:  brew install qemu" >&2
  exit 1
fi

release_vm_lock() {
  if [[ ${VM_LOCK_HELD} -eq 1 ]]; then
    rm -f -- "${VM_LOCK}/pid"
    rmdir -- "${VM_LOCK}" 2>/dev/null || true
    VM_LOCK_HELD=0
  fi
}

cleanup() {
  local status=$?
  local bridge_pid=""
  trap - EXIT INT TERM
  if [[ -n ${BRIDGE_PID_FILE} && -r ${BRIDGE_PID_FILE} ]]; then
    read -r bridge_pid < "${BRIDGE_PID_FILE}" || true
    if [[ ${bridge_pid} =~ ^[0-9]+$ ]]; then
      kill "${bridge_pid}" 2>/dev/null || true
    fi
  fi
  if [[ -n ${BRIDGE_SUPERVISOR_PID} ]]; then
    kill "${BRIDGE_SUPERVISOR_PID}" 2>/dev/null || true
    wait "${BRIDGE_SUPERVISOR_PID}" 2>/dev/null || true
  fi
  if [[ -n ${QEMU_PID} ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
    kill "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
  fi
  if [[ ${RUNTIME_DESCRIPTOR_OWNED} -eq 1 ]]; then
    rm -f -- "${RUNTIME_DESCRIPTOR}"
  fi
  if [[ -n ${RUNTIME_DIR} && -d ${RUNTIME_DIR} ]]; then
    rm -f -- "${RUNTIME_DIR}/qmp.sock" "${RUNTIME_DIR}/audio.sock" \
      "${RUNTIME_DIR}/clipboard.sock"
    rm -f -- "${RUNTIME_DIR}/clipboard-bridge.pid"
    if [[ -d ${RUNTIME_DIR}/audio-routes && ! -L ${RUNTIME_DIR}/audio-routes ]]; then
      rm -f -- "${RUNTIME_DIR}/audio-routes/input" "${RUNTIME_DIR}/audio-routes/output"
      rmdir -- "${RUNTIME_DIR}/audio-routes" 2>/dev/null || true
    fi
    rmdir -- "${RUNTIME_DIR}" 2>/dev/null || true
  fi
  release_vm_lock
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_vm_lock() {
  local disk_owner lock_owner
  disk_owner="$(/usr/sbin/lsof -t -- "${DISK}" 2>/dev/null | head -1 || true)"
  if [[ -n ${disk_owner} ]]; then
    echo "error: Bento is already running (PID ${disk_owner} has ${DISK} open)" >&2
    exit 1
  fi

  if ! mkdir -m 0700 -- "${VM_LOCK}" 2>/dev/null; then
    lock_owner=""
    if [[ -r ${VM_LOCK}/pid ]]; then
      read -r lock_owner < "${VM_LOCK}/pid" || true
    fi
    if [[ ${lock_owner} =~ ^[0-9]+$ ]] && kill -0 "${lock_owner}" 2>/dev/null; then
      echo "error: Bento is already running (launcher PID ${lock_owner})" >&2
      exit 1
    fi
    if [[ -z ${lock_owner} ]]; then
      echo "error: another Bento launch is acquiring ${VM_LOCK}" >&2
      exit 1
    fi
    rm -f -- "${VM_LOCK}/pid"
    rmdir -- "${VM_LOCK}" 2>/dev/null || {
      echo "error: cannot clear stale VM lock: ${VM_LOCK}" >&2
      exit 1
    }
    mkdir -m 0700 -- "${VM_LOCK}"
  fi
  printf '%s\n' "$$" > "${VM_LOCK}/pid"
  chmod 0600 "${VM_LOCK}/pid"
  VM_LOCK_HELD=1
}

acquire_vm_lock
RUNTIME_DESCRIPTOR_OWNED=1
rm -f -- "${RUNTIME_DESCRIPTOR}"
RUNTIME_DIR="$(mktemp -d "${ARTIFACTS}/runtime.XXXXXX")"
chmod 0700 "${RUNTIME_DIR}"
QMP_SOCK="${RUNTIME_DIR}/qmp.sock"
AUDIO_SOCK="${RUNTIME_DIR}/audio.sock"
AUDIO_ROUTE_DIR="${RUNTIME_DIR}/audio-routes"
CLIPBOARD_SOCK="${RUNTIME_DIR}/clipboard.sock"
BRIDGE_PID_FILE="${RUNTIME_DIR}/clipboard-bridge.pid"
mkdir -m 0700 -- "${AUDIO_ROUTE_DIR}"

if [[ -x ${PATCHED_QEMU} ]]; then
  QEMU="${PATCHED_QEMU}"
  PATCHED_RUNTIME=1
fi

if [[ ${GL} == auto ]]; then
  if [[ ${PATCHED_RUNTIME} -eq 1 ]]; then GL=1; else GL=0; fi
elif [[ ${GL} -eq 1 && ${PATCHED_RUNTIME} -eq 0 ]]; then
  echo "error: no GL-capable Bento QEMU at ${PATCHED_QEMU}" >&2
  echo "       build it first:  ./scripts/build-qemu-gl.sh" >&2
  exit 1
fi

if [[ ${HEADLESS} -eq 1 ]]; then
  if [[ ${GL} -eq 1 && ${GL_EXPLICIT} -eq 1 ]]; then
    echo "error: --gl and --headless are mutually exclusive" >&2
    exit 2
  fi
  GL=0
fi

qemu_version="$("${QEMU}" --version | head -1)"
if [[ ${PATCHED_RUNTIME} -eq 1 && ${qemu_version} != "QEMU emulator version 11.1.1"* ]]; then
  echo "error: Bento's patched runtime must be QEMU 11.1.1; found: ${qemu_version}" >&2
  exit 1
fi

device_help="$("${QEMU}" -device help 2>/dev/null || true)"
if [[ ( ${CLIPBOARD} -eq 1 || ${AUDIO} -eq 1 ) && ${device_help} != *"virtio-serial-pci"* ]]; then
  echo "error: the selected QEMU runtime has no virtio-serial support" >&2
  exit 1
fi
if [[ ${AUDIO} -eq 1 ]]; then
  audio_help="$("${QEMU}" -machine virt -audiodev help 2>&1 || true)"
  if [[ ${audio_help} != "sdl" && ${audio_help} != *$'\nsdl\n'* \
        && ${audio_help} != sdl$'\n'* && ${audio_help} != *$'\nsdl' ]]; then
    echo "error: the selected QEMU runtime has no SDL audio backend" >&2
    echo "       rebuild it first:  ./scripts/build-qemu-gl.sh --clean" >&2
    exit 1
  fi
  for device in intel-hda hda-micro virtserialport; do
    if [[ ${device_help} != *"${device}"* ]]; then
      echo "error: the selected QEMU runtime has no ${device} audio support" >&2
      exit 1
    fi
  done
fi
if [[ -n ${SHARE_PATH} ]]; then
  if [[ ${PATCHED_RUNTIME} -eq 0 ]]; then
    echo "error: --share requires Bento's guest-owner-capable QEMU runtime" >&2
    echo "       build it first:  ./scripts/build-qemu-gl.sh" >&2
    exit 1
  fi
  if [[ ${device_help} != *"virtio-9p-pci"* ]]; then
    echo "error: Bento's QEMU runtime has no virtio-9p support; rebuild it" >&2
    exit 1
  fi
  fsdev_help="$("${QEMU}" -fsdev local,help 2>&1 || true)"
  if [[ ${fsdev_help} != *"uid=<num>"* || ${fsdev_help} != *"gid=<num>"* ]]; then
    echo "error: Bento's QEMU runtime lacks the pinned 9p guest-owner patch; rebuild it" >&2
    exit 1
  fi
fi

gpu_device="virtio-gpu-pci,max_outputs=1,xres=${GPU_XRES},yres=${GPU_YRES}"
GPU_MODE="software"
cocoa_opts="cocoa"
if [[ ${GL} -eq 1 ]]; then
  gpu_device="virtio-gpu-gl-pci,max_outputs=1,xres=${GPU_XRES},yres=${GPU_YRES}"
  GPU_MODE="virgl"
  cocoa_opts+=",gl=es"
fi

cocoa_opts+=",show-cursor=on,zoom-to-fit=on"
if [[ ${WINDOWED} -eq 1 ]]; then
  cocoa_opts+=",full-screen=off"
  if [[ ${PATCHED_RUNTIME} -eq 1 ]]; then cocoa_opts+=",immersive=off"; fi
else
  cocoa_opts+=",full-screen=on"
  if [[ ${PATCHED_RUNTIME} -eq 1 ]]; then cocoa_opts+=",immersive=on"; fi
fi
cocoa_opts+=",swap-opt-cmd=off"
if [[ ${GRAB} -eq 1 ]]; then cocoa_opts+=",full-grab=on"; fi

display_args=(-display "${cocoa_opts}")
if [[ ${HEADLESS} -eq 1 ]]; then display_args=(-display none); fi

machine="virt,accel=hvf"
if [[ ${PATCHED_RUNTIME} -eq 1 ]]; then machine+=",gic-version=3"; fi

# The integration devices are appended after the boot disk, but the topology marker still
# changes once so every existing EFI store is rediscovered under the QEMU 11.1 layout.
efi_profile="qemu=${qemu_version}|machine=${machine}|gpu=${gpu_device%%,*}|topology=bento-20260905-v4"
saved_efi_profile=""
if [[ -r ${VARS_PROFILE} ]]; then IFS= read -r saved_efi_profile < "${VARS_PROFILE}" || true; fi
reset_vars_reason=""
if [[ ${RESET_VARS} -eq 1 ]]; then
  reset_vars_reason="requested by --reset-vars"
elif [[ ! -f ${VARS} ]]; then
  reset_vars_reason="no variable store exists"
elif [[ ${saved_efi_profile} != "${efi_profile}" ]]; then
  reset_vars_reason="the emulated hardware profile changed"
fi
if [[ -n ${reset_vars_reason} ]]; then
  echo "==> Creating a blank 64 MiB EFI variable store (${reset_vars_reason})"
  rm -f -- "${VARS}"
  dd if=/dev/zero of="${VARS}" bs=1m count="${BENTO_EFI_VARS_SIZE_MB:-64}" status=none
  printf '%s\n' "${efi_profile}" > "${VARS_PROFILE}"
  chmod 0600 "${VARS}" "${VARS_PROFILE}"
fi

qemu_data_args=()
if [[ ${PATCHED_RUNTIME} -eq 1 && -n ${QEMU_DATA} ]]; then qemu_data_args=(-L "${QEMU_DATA}"); fi
integration_args=()
if [[ ${AUDIO} -eq 1 || ${CLIPBOARD} -eq 1 ]]; then
  integration_args+=(
    -device "virtio-serial-pci,id=bento-integrations,romfile="
  )
fi
if [[ ${AUDIO} -eq 1 ]]; then
  integration_args+=(
    -chardev "socket,id=bento-audio-bridge,path=${AUDIO_SOCK},server=on,wait=off"
    -device "virtserialport,bus=bento-integrations.0,nr=1,chardev=bento-audio-bridge,name=dev.bento.audio"
  )
fi
if [[ ${CLIPBOARD} -eq 1 ]]; then
  integration_args+=(
    -chardev "socket,id=bento-clipboard,path=${CLIPBOARD_SOCK},server=on,wait=off"
    -device "virtserialport,bus=bento-integrations.0,nr=2,chardev=bento-clipboard,name=dev.bento.clipboard"
  )
fi
if [[ -n ${SHARE_PATH} ]]; then
  integration_args+=(
    -fsdev "local,id=bento-mac,path=${SHARE_PATH},security_model=none,multidevs=remap,uid=1000,gid=100"
    -device "virtio-9p-pci,fsdev=bento-mac,mount_tag=bento-mac,romfile="
  )
fi

echo "==> Booting bento (${CPUS} cpus, ${MEMORY}, ssh on 127.0.0.1:${SSH_PORT})"
echo "    runtime: ${qemu_version}"
if [[ ${GL} -eq 1 ]]; then
  echo "    graphics: VirGL through ANGLE/Metal"
elif [[ ${HEADLESS} -eq 1 ]]; then
  echo "    graphics: software scanout, headless"
else
  echo "    graphics: software-rendered Cocoa display"
fi
if [[ -n ${SHARE_PATH} ]]; then echo "    folder: ${SHARE_PATH} -> ~/Mac"; else echo "    folder: disabled"; fi
if [[ ${CLIPBOARD} -eq 1 ]]; then echo "    clipboard: automatic text/PNG sharing"; else echo "    clipboard: disabled"; fi
if [[ ${AUDIO} -eq 1 ]]; then echo "    audio: SDL speaker and microphone integration"; else echo "    audio: disabled"; fi
echo "    serial console follows; Ctrl-A X to kill the VM"
echo

audio_args=()
if [[ ${AUDIO} -eq 1 ]]; then
  audio_args=(
    -audiodev "sdl,id=bento-audio"
    -device "intel-hda,id=bento-hda,romfile="
    -device "hda-micro,bus=bento-hda.0,audiodev=bento-audio"
  )
  # SDL's legacy variable selects one process-wide device. Bento's patched
  # backend instead receives independent input/output routes and live updates.
  unset SDL_AUDIO_DEVICE_NAME
  export BENTO_SDL_AUDIO_CONTROL_DIRECTORY="${AUDIO_ROUTE_DIR}"
fi

"${QEMU}" \
  ${qemu_data_args[@]+"${qemu_data_args[@]}"} \
  -name bento \
  -machine "${machine}" \
  -cpu host,pmu=off \
  -smp "${CPUS},sockets=1,cores=${CPUS},threads=1" \
  -m "${MEMORY}" \
  -nodefaults \
  -action reboot=reset,shutdown=poweroff \
  -boot strict=on \
  -drive "if=pflash,format=raw,readonly=on,file=${CODE}" \
  -drive "if=pflash,format=raw,file=${VARS}" \
  -drive "if=none,id=bento-disk,format=qcow2,file=${DISK}" \
  -device "virtio-blk-pci,drive=bento-disk,bootindex=1,romfile=" \
  -device "${gpu_device}" \
  "${display_args[@]}" \
  -qmp "unix:${QMP_SOCK},server=on,wait=off" \
  -device virtio-keyboard-pci,romfile= \
  -device virtio-tablet-pci,romfile= \
  -object rng-random,id=bento-rng,filename=/dev/urandom \
  -device virtio-rng-pci,rng=bento-rng \
  ${audio_args[@]+"${audio_args[@]}"} \
  ${integration_args[@]+"${integration_args[@]}"} \
  -netdev "user,id=bento-net,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
  -device "virtio-net-pci,netdev=bento-net,romfile=" \
  -serial mon:stdio &
QEMU_PID=$!

/usr/bin/python3 - "${RUNTIME_DESCRIPTOR}" "${QMP_SOCK}" "${QEMU_PID}" "${SSH_PORT}" "${GPU_MODE}" "${AUDIO}" "${AUDIO_SOCK}" "${AUDIO_ROUTE_DIR}" <<'PY'
import json
import os
import sys

target, qmp, pid, port, gpu, audio_enabled, audio_socket, audio_routes = sys.argv[1:]
temporary = target + ".tmp"
descriptor = {
    "version": 2,
    "qmp": qmp,
    "pid": int(pid),
    "sshPort": int(port),
    "gpu": gpu,
    "audio": audio_enabled == "1",
}
if descriptor["audio"]:
    descriptor["audioSocket"] = audio_socket
    descriptor["audioRoutes"] = audio_routes
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(descriptor, stream)
    stream.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, target)
PY
chmod 0600 "${RUNTIME_DESCRIPTOR}"
echo "    runtime descriptor: ${RUNTIME_DESCRIPTOR}"

if [[ ${CLIPBOARD} -eq 1 ]]; then
  if [[ -x ${CLIPBOARD_BRIDGE} ]]; then
    (
      bridge_pid=""
      stop_bridge() {
        trap - EXIT INT TERM
        if [[ ${bridge_pid} =~ ^[0-9]+$ ]]; then
          kill "${bridge_pid}" 2>/dev/null || true
          wait "${bridge_pid}" 2>/dev/null || true
        fi
        rm -f -- "${BRIDGE_PID_FILE}"
        exit 0
      }
      trap stop_bridge EXIT INT TERM
      while kill -0 "${QEMU_PID}" 2>/dev/null; do
        "${CLIPBOARD_BRIDGE}" --socket "${CLIPBOARD_SOCK}" &
        bridge_pid=$!
        printf '%s\n' "${bridge_pid}" > "${BRIDGE_PID_FILE}"
        wait "${bridge_pid}" || true
        bridge_pid=""
        rm -f -- "${BRIDGE_PID_FILE}"
        kill -0 "${QEMU_PID}" 2>/dev/null || break
        echo "warning: clipboard bridge stopped; restarting" >&2
        sleep 1
      done
    ) &
    BRIDGE_SUPERVISOR_PID=$!
  else
    echo "warning: clipboard bridge unavailable at ${CLIPBOARD_BRIDGE}; VM startup continues" >&2
  fi
fi

set +e
wait "${QEMU_PID}"
qemu_status=$?
set -e
QEMU_PID=""
exit "${qemu_status}"
