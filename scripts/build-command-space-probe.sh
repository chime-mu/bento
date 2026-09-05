#!/usr/bin/env bash
# Build the smallest useful host-side experiment for macOS Command-Space capture.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_DIR="${REPO_ROOT}/macos"
BUILD_DIR="${REPO_ROOT}/artifacts/command-space-probe-build"
APP="${REPO_ROOT}/artifacts/app.noindex/Command-Space Probe.app"
DESTINATION="/Applications/Command-Space Probe.app"
INSTALL=0

case "${1:-}" in
  "") ;;
  --install) INSTALL=1 ;;
  -h|--help)
    echo "usage: $0 [--install]"
    exit 0
    ;;
  *)
    echo "usage: $0 [--install]" >&2
    exit 64
    ;;
esac

plutil -lint "${SOURCE_DIR}/CommandSpaceProbe-Info.plist" >/dev/null
mkdir -p "${BUILD_DIR}/module-cache" "$(dirname -- "${APP}")"

STAGE="$(mktemp -d "${BUILD_DIR}/stage.XXXXXX")"
trap 'rm -rf -- "${STAGE}"' EXIT
STAGED_APP="${STAGE}/Command-Space Probe.app"
CONTENTS="${STAGED_APP}/Contents"
mkdir -p "${CONTENTS}/MacOS"

xcrun swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  "${SOURCE_DIR}/CommandSpaceProbe.swift" \
  -o "${CONTENTS}/MacOS/CommandSpaceProbe"
install -m 0644 "${SOURCE_DIR}/CommandSpaceProbe-Info.plist" "${CONTENTS}/Info.plist"

codesign --force --sign - --identifier dev.bento.command-space-probe \
  "${CONTENTS}/MacOS/CommandSpaceProbe"
codesign --force --sign - --identifier dev.bento.command-space-probe "${STAGED_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"

rm -rf -- "${APP}"
ditto "${STAGED_APP}" "${APP}"
echo "==> Built ${APP}"

if [[ ${INSTALL} -eq 1 ]]; then
  if [[ -e ${DESTINATION} || -L ${DESTINATION} ]]; then
    echo "error: refusing to replace ${DESTINATION}; its ad-hoc permission is code-hash-specific" >&2
    exit 1
  fi
  ditto "${APP}" "${DESTINATION}"
  codesign --verify --deep --strict --verbose=2 "${DESTINATION}"
  echo "==> Installed ${DESTINATION}"
fi
