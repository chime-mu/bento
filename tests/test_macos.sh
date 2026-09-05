#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bento-macos-tests.XXXXXX")"
trap 'rm -rf -- "${BUILD_DIR}"' EXIT

xcrun swiftc \
  -target arm64-apple-macos13.0 \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  -framework AppKit \
  -framework CryptoKit \
  "${REPO_ROOT}/macos/BentoLauncherCore.swift" \
  "${REPO_ROOT}/macos/ClipboardBridgeCore.swift" \
  "${REPO_ROOT}/macos/tests/BentoCoreTests.swift" \
  -o "${BUILD_DIR}/BentoCoreTests"

cd "${REPO_ROOT}"
"${BUILD_DIR}/BentoCoreTests"
