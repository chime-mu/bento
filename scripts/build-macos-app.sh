#!/usr/bin/env bash
# Build the small native launcher that gives Bento its own macOS privacy identity.

set -euo pipefail
umask 077

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-64}"
}

# Usage:
#   ./scripts/build-macos-app.sh
#   ./scripts/build-macos-app.sh --install
#   ./scripts/build-macos-app.sh --install --destination /Applications/Bento.app
#   ./scripts/build-macos-app.sh --sign-identity "Developer ID Application: ..."
#
# The VM disk stays outside the bundle. Bento.app embeds the project-built QEMU runtime
# and signs it with Bento's product identity, just like the launcher. The launcher runs
# scripts/run-vm.sh from this checkout and remains QEMU's parent for the life of the VM.
#
# --install copies the finished app to /Applications/Bento.app. It deliberately refuses
# to overwrite an existing app so replacing the runnable VM is always explicit.

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_DIR="${REPO_ROOT}/macos"
BUILD_DIR="${REPO_ROOT}/artifacts/macos-app-build"
APP="${REPO_ROOT}/artifacts/app.noindex/Bento.app"
DEVELOPER_BRIDGE="${REPO_ROOT}/artifacts/bin/BentoClipboardBridge"
QEMU_SOURCE="${BENTO_QEMU_SOURCE:-${HOME}/.local/state/bento/qemu-gl/bin/qemu-system-aarch64}"
QEMU_PREFIX="$(cd -- "$(dirname -- "${QEMU_SOURCE}")/.." && pwd -P)"
QEMU_DATA_SOURCE="${BENTO_QEMU_DATA_SOURCE:-${QEMU_PREFIX}/share/qemu}"
INSTALL=0
DESTINATION="/Applications/Bento.app"
SIGN_IDENTITY="${BENTO_CODESIGN_IDENTITY:--}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --destination)
      [[ $# -ge 2 ]] || usage
      DESTINATION="$2"
      shift 2
      ;;
    --sign-identity)
      [[ $# -ge 2 ]] || usage
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    -h|--help) usage 0 ;;
    *) usage ;;
  esac
done

for tool in codesign ditto install_name_tool otool plutil xattr xcrun; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "error: ${tool} is required" >&2
    exit 1
  }
done

if [[ ! -x ${QEMU_SOURCE} ]]; then
  echo "error: Bento's patched QEMU is missing: ${QEMU_SOURCE}" >&2
  echo "       build it first: ./scripts/build-qemu-gl.sh" >&2
  exit 1
fi
if [[ ! -f ${QEMU_DATA_SOURCE}/efi-virtio.rom ]]; then
  echo "error: QEMU's EFI option ROM is missing: ${QEMU_DATA_SOURCE}/efi-virtio.rom" >&2
  exit 1
fi
device_help="$("${QEMU_SOURCE}" -device help 2>/dev/null || true)"
fsdev_help="$("${QEMU_SOURCE}" -fsdev local,help 2>&1 || true)"
audio_help="$("${QEMU_SOURCE}" -machine virt -audiodev help 2>&1 || true)"
png_link="$(otool -L "${QEMU_SOURCE}" | grep -i 'libpng' || true)"
SDL2_LINK="$(otool -L "${QEMU_SOURCE}" | awk '/libSDL2-2\.0\.0\.dylib/ {print $1; exit}')"
SDL2_SOURCE="${QEMU_PREFIX}/lib/libSDL2-2.0.0.dylib"
SDL3_SOURCE="${QEMU_PREFIX}/lib/libSDL3.dylib"
if [[ ${device_help} != *"virtio-serial-pci"* || ${device_help} != *"virtio-9p-pci"* \
      || ${fsdev_help} != *"uid=<num>"* || ${fsdev_help} != *"gid=<num>"* \
      || ${audio_help} != *"sdl"* \
      || ${SDL2_LINK} != '@loader_path/../lib/libSDL2-2.0.0.dylib' \
      || ! -f ${SDL2_SOURCE} || ! -f ${SDL3_SOURCE} || -z ${png_link} ]]; then
  echo "error: ${QEMU_SOURCE} lacks Bento's clipboard/9p/PNG/SDL support" >&2
  echo "       rebuild it first: ./scripts/build-qemu-gl.sh --clean" >&2
  exit 1
fi

plutil -lint "${SOURCE_DIR}/Info.plist" >/dev/null
mkdir -p "${BUILD_DIR}/module-cache" "$(dirname -- "${APP}")"
chmod 0700 "${REPO_ROOT}/artifacts"

STAGE="$(mktemp -d "${BUILD_DIR}/stage.XXXXXX")"
trap 'rm -rf -- "${STAGE}"' EXIT
STAGED_APP="${STAGE}/Bento.app"
CONTENTS="${STAGED_APP}/Contents"
QEMU="${CONTENTS}/Resources/runtime/bin/BentoQEMU"
QEMU_DATA="${CONTENTS}/Resources/runtime/share/qemu"
QEMU_LIB="${CONTENTS}/Resources/runtime/lib"
BRIDGE="${CONTENTS}/Helpers/BentoClipboardBridge"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Helpers" "$(dirname -- "${QEMU}")" "${QEMU_DATA}" "${QEMU_LIB}"

xcrun swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  -framework AppKit \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework CoreAudio \
  "${SOURCE_DIR}/BentoLauncherCore.swift" \
  "${SOURCE_DIR}/AudioIntegration.swift" \
  "${SOURCE_DIR}/QMPConnection.swift" \
  "${SOURCE_DIR}/VMHostSleepController.swift" \
  "${SOURCE_DIR}/BentoLauncher.swift" \
  -o "${CONTENTS}/MacOS/BentoLauncher"

xcrun swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  -framework AppKit \
  -framework CryptoKit \
  "${SOURCE_DIR}/ClipboardBridgeCore.swift" \
  "${SOURCE_DIR}/BentoClipboardBridge.swift" \
  -o "${BRIDGE}"

install -m 0644 "${SOURCE_DIR}/Info.plist" "${CONTENTS}/Info.plist"
printf '%s\n' "${REPO_ROOT}" > "${CONTENTS}/Resources/repository-path"
install -m 0755 "${QEMU_SOURCE}" "${QEMU}"
install -m 0644 "${QEMU_DATA_SOURCE}/efi-virtio.rom" "${QEMU_DATA}/efi-virtio.rom"
install -m 0755 "${SDL2_SOURCE}" "${QEMU_LIB}/libSDL2-2.0.0.dylib"
install -m 0755 "${SDL3_SOURCE}" "${QEMU_LIB}/libSDL3.dylib"
# QEMU's upstream install attaches a classic Mac resource fork before signing. It is not
# needed here and would prevent the nested copy from being signed as part of Bento.app.
xattr -c "${QEMU}"
xattr -c "${QEMU_LIB}/libSDL2-2.0.0.dylib" "${QEMU_LIB}/libSDL3.dylib"

SIGN_OPTIONS=(--force --sign "${SIGN_IDENTITY}")
if [[ ${SIGN_IDENTITY} != - ]]; then
  SIGN_OPTIONS+=(--options runtime --timestamp)
fi
codesign "${SIGN_OPTIONS[@]}" "${QEMU_LIB}/libSDL3.dylib"
codesign "${SIGN_OPTIONS[@]}" "${QEMU_LIB}/libSDL2-2.0.0.dylib"
codesign "${SIGN_OPTIONS[@]}" --identifier dev.bento.vm \
  --entitlements "${SOURCE_DIR}/qemu-hvf.entitlements" "${QEMU}"
codesign "${SIGN_OPTIONS[@]}" --identifier dev.bento.vm.clipboard "${BRIDGE}"
codesign "${SIGN_OPTIONS[@]}" --identifier dev.bento.vm \
  --entitlements "${SOURCE_DIR}/bento.entitlements" \
  "${CONTENTS}/MacOS/BentoLauncher"
codesign "${SIGN_OPTIONS[@]}" --identifier dev.bento.vm \
  --entitlements "${SOURCE_DIR}/bento.entitlements" "${STAGED_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"
codesign --verify --strict --verbose=2 "${QEMU}"
codesign --verify --strict --verbose=2 "${QEMU_LIB}/libSDL2-2.0.0.dylib"
codesign --verify --strict --verbose=2 "${QEMU_LIB}/libSDL3.dylib"
codesign -d --entitlements - "${QEMU}" 2>&1 \
  | grep -q 'com.apple.security.hypervisor'
codesign -d --entitlements - "${QEMU}" 2>&1 \
  | grep -q 'com.apple.security.device.audio-input'
codesign -d --entitlements - "${STAGED_APP}" 2>&1 \
  | grep -q 'com.apple.security.device.audio-input'
[[ -n $(plutil -extract NSMicrophoneUsageDescription raw "${CONTENTS}/Info.plist") ]] || {
  echo "error: Bento.app has no microphone usage description" >&2
  exit 1
}

rm -rf -- "${APP}"
ditto "${STAGED_APP}" "${APP}"
codesign --verify --deep --strict --verbose=2 "${APP}"

# Direct run-vm.sh launches use the same bridge without needing to reach inside the app.
mkdir -p "$(dirname -- "${DEVELOPER_BRIDGE}")"
install -m 0755 "${BRIDGE}" "${DEVELOPER_BRIDGE}"
codesign "${SIGN_OPTIONS[@]}" --identifier dev.bento.vm.clipboard "${DEVELOPER_BRIDGE}"

echo "==> Built ${APP}"
echo "    bundle id: dev.bento.vm"
echo "    QEMU: embedded, signed as dev.bento.vm"
echo "    clipboard bridge: embedded and ${DEVELOPER_BRIDGE}"
echo "    repository: ${REPO_ROOT}"

if [[ ${INSTALL} -eq 1 ]]; then
  if [[ -e ${DESTINATION} || -L ${DESTINATION} ]]; then
    echo "error: refusing to overwrite existing app: ${DESTINATION}" >&2
    echo "       move or remove the old copy knowingly before installing a rebuild" >&2
    exit 1
  fi
  mkdir -p "$(dirname -- "${DESTINATION}")"
  ditto "${APP}" "${DESTINATION}"
  codesign --verify --deep --strict --verbose=2 "${DESTINATION}"
  echo "==> Installed ${DESTINATION}"
  echo "    Command-Space capture does not require Accessibility permission."
fi
