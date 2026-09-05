#!/usr/bin/env bash
# Build the small native launcher that gives Bento its own macOS privacy identity.

set -euo pipefail

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

for tool in codesign ditto plutil xattr xcrun; do
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

plutil -lint "${SOURCE_DIR}/Info.plist" >/dev/null
mkdir -p "${BUILD_DIR}/module-cache" "$(dirname -- "${APP}")"

STAGE="$(mktemp -d "${BUILD_DIR}/stage.XXXXXX")"
trap 'rm -rf -- "${STAGE}"' EXIT
STAGED_APP="${STAGE}/Bento.app"
CONTENTS="${STAGED_APP}/Contents"
QEMU="${CONTENTS}/Resources/runtime/bin/BentoQEMU"
QEMU_DATA="${CONTENTS}/Resources/runtime/share/qemu"
mkdir -p "${CONTENTS}/MacOS" "$(dirname -- "${QEMU}")" "${QEMU_DATA}"

xcrun swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  -framework AppKit \
  "${SOURCE_DIR}/BentoLauncher.swift" \
  -o "${CONTENTS}/MacOS/BentoLauncher"

install -m 0644 "${SOURCE_DIR}/Info.plist" "${CONTENTS}/Info.plist"
printf '%s\n' "${REPO_ROOT}" > "${CONTENTS}/Resources/repository-path"
install -m 0755 "${QEMU_SOURCE}" "${QEMU}"
install -m 0644 "${QEMU_DATA_SOURCE}/efi-virtio.rom" "${QEMU_DATA}/efi-virtio.rom"
# QEMU's upstream install attaches a classic Mac resource fork before signing. It is not
# needed here and would prevent the nested copy from being signed as part of Bento.app.
xattr -c "${QEMU}"

SIGN_OPTIONS=(--force --sign "${SIGN_IDENTITY}")
if [[ ${SIGN_IDENTITY} != - ]]; then
  SIGN_OPTIONS+=(--options runtime --timestamp)
fi
codesign "${SIGN_OPTIONS[@]}" --identifier dev.bento.vm \
  --entitlements "${SOURCE_DIR}/qemu-hvf.entitlements" "${QEMU}"
codesign "${SIGN_OPTIONS[@]}" --identifier dev.bento.vm \
  "${CONTENTS}/MacOS/BentoLauncher"
codesign "${SIGN_OPTIONS[@]}" --identifier dev.bento.vm "${STAGED_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"

rm -rf -- "${APP}"
ditto "${STAGED_APP}" "${APP}"
codesign --verify --deep --strict --verbose=2 "${APP}"

echo "==> Built ${APP}"
echo "    bundle id: dev.bento.vm"
echo "    QEMU: embedded, signed as dev.bento.vm"
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
