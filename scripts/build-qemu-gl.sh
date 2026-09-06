#!/usr/bin/env bash
# bento — build a GL-capable qemu-system-aarch64 for the macOS host.
#
#   ./scripts/build-qemu-gl.sh            # build, install, verify the hvf entitlement
#   ./scripts/build-qemu-gl.sh --check    # just report what is installed
#   ./scripts/build-qemu-gl.sh --clean    # throw the source tree away first
#
# Needs no sudo. Nothing here touches /etc, /usr, or the Homebrew `qemu` formula
# that Phases 1-5 boot the VM with — the result lands in its own prefix under
# ~/.local/state/bento, the same place Phase 0 put the linux-builder's keys.
#
# WHY THIS EXISTS (learned/phase-0.md §2, learned/phase-6.md §1)
#
# Homebrew's qemu has no OpenGL compiled in: `virtio-gpu-gl-pci` does not exist and
# `-display cocoa,gl=es` errors out. That is not a flag we forgot, it is a property of
# the binary, so GL means *replacing* it. Upstream QEMU cannot be simply reconfigured
# either: `ui/cocoa.m` contains no GL code at all, in 10.1, in 11.1 and in master.
#
# Three things have to come together, and all three are load-bearing:
#
#   1. ANGLE          — macOS deprecated OpenGL at 4.1 and has no EGL at all. ANGLE
#                       translates GL ES to Metal and supplies the EGL that
#                       virglrenderer wants. Homebrew core has no ANGLE; the bottles
#                       come from the startergo/qemu-virgl tap.
#   2. libepoxy-angle — epoxy built against that ANGLE rather than the system GL, so
#                       QEMU and virglrenderer resolve the same symbols.
#   3. the patches    — Try Omarchy's QEMU 11.1 Cocoa/VirGL series decouples
#                       CONFIG_EGL from CONFIG_OPENGL, adds Cocoa texture borrowing,
#                       and supplies the Metal-backed scanout path. Its dirty-frame fix
#                       prevents Cocoa from needlessly redrawing that scanout on every
#                       refresh tick. The display patches publish live backing-pixel
#                       geometry through virtio-gpu EDID and separate immersive mode
#                       from keyboard capture. Bento's Carbon patch handles the macOS 26
#                       case where WindowServer withholds Space even from a HID event tap.
#
# QEMU 11.1 is also the first release whose ARM virt machine uses HVF's native GICv3
# interrupt controller. That keeps interrupt injection out of QEMU's global lock and is
# the main reason to build this release rather than carrying the Cocoa series on 10.1.
#
# We build rather than pouring the tap's `qemu-virgl` bottle because that bottle links
# libspice-server, and spice-server pulls gstreamer and ~60 further formulae onto the
# host, plus upgrades of 20 unrelated ones. `--disable-spice` costs a compile and
# nothing else: every remaining dependency was already installed for Homebrew's qemu.
#
# Code signing is not optional. macOS gates hardware virtualization and microphone
# capture behind entitlements. QEMU's install hook supplies only the former and also
# attaches a classic resource fork, so the final stage clears that metadata and signs
# the binary with Bento's entitlement superset.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${HOME}/.local/state/bento"
SRC_DIR="${STATE}/qemu-gl-src"
PREFIX="${STATE}/qemu-gl"
VIRGL_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-macos-virgl.patch"
GPU_DIRTY_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-macos-gpu-dirty-flag.patch"
DYNAMIC_DISPLAY_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-macos-dynamic-display.patch"
IMMERSIVE_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-macos-immersive-mode.patch"
FULL_GRAB_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-macos-full-grab-focus.patch"
COMMAND_SPACE_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-macos-command-space-carbon.patch"
PAUSE_OWNERSHIP_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-macos-pause-ownership.patch"
SDL_AUDIO_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-sdl-audio-routing.patch"
STRCHRNUL_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-darwin-strchrnul-compat.patch"
VIRTFS_OWNER_PATCH="${REPO_ROOT}/scripts/patches/qemu-11.1-virtfs-guest-owner.patch"
PINNED_SDL="${REPO_ROOT}/scripts/pinned-sdl-runtime.sh"
QEMU_ENTITLEMENTS="${REPO_ROOT}/macos/qemu-hvf.entitlements"

QEMU_VERSION="11.1.1"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
QEMU_SHA256="079ffbff8a7111bbc89022107cbabf3bbfd614d5fc9d7cc675991196aca12482"

# QEMU's release archive carries the dtc wrap but not the wrapped source. Pin the same
# commit QEMU requests and stage it locally so --disable-download can enforce an offline
# configure. QEMU's Python environment likewise needs these wheels on Python 3.12+.
DTC_COMMIT="b6910bec11614980a21e46fbccc35934b671bd81"
DTC_TARBALL="dtc-${DTC_COMMIT}.tar.gz"
DTC_URL="https://gitlab.com/qemu-project/dtc/-/archive/${DTC_COMMIT}/${DTC_TARBALL}"
DTC_SHA256="e115f987eec23a1ba25150a46ced1675de3716072d3b4905afb3a9cda0f007c7"

SETUPTOOLS_WHEEL="setuptools-84.0.0-py3-none-any.whl"
SETUPTOOLS_URL="https://files.pythonhosted.org/packages/95/9c/c510029fc6ef33a6275cd2c5d3cecd6613dfd6aa401d57c54f1c18852ccf/${SETUPTOOLS_WHEEL}"
SETUPTOOLS_SHA256="51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670"
WHEEL_WHEEL="wheel-0.48.0-py3-none-any.whl"
WHEEL_URL="https://files.pythonhosted.org/packages/2e/29/69cfbb602cd91690c55d38ba9fe53e6a7e76a6fa647bf38f19c138d25449/${WHEEL_WHEEL}"
WHEEL_SHA256="3217dcc807155e45db462d7ef2431f5ddda0d7273b700d05a67b271ceb1287ab"
PIP_WHEEL="pip-26.2.1-py3-none-any.whl"
PIP_URL="https://files.pythonhosted.org/packages/f3/6e/1736e5b4ae2b778ef2f81c47d797de9f891d4d8acb047a24ca37a60294dd/${PIP_WHEEL}"
PIP_SHA256="71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e"

VIRGL_PATCH_SHA256="b20bdf9a7d7ccda5b86366ad9d09a3bf95308b98a06b1ece281344405bcc7ab9"
GPU_DIRTY_PATCH_SHA256="b554e1ef9910d0891d69ee0fe84e479559c057dc28291e36e1524031808fc69f"
DYNAMIC_DISPLAY_PATCH_SHA256="1ce59350b6b8e6842bc0c9ca34c97f54cb75e85e2d7b35e5b483858654c4d693"
IMMERSIVE_PATCH_SHA256="2462463932f7db0d659f754f7f9c182884564dbcd7d4b8e523f1b57f0bd9fe5b"
FULL_GRAB_PATCH_SHA256="d94aaa7b8b8b97eb25a5ace2b3a1268985e1b16e4e6201847b926b8ee709dbfb"
COMMAND_SPACE_PATCH_SHA256="9164887a716ed67ced68f13d39d67d73d18f50a612945f9cf8e5ecdb9b22a5ab"
PAUSE_OWNERSHIP_PATCH_SHA256="f9dc49aa6498fb3819ec1fa82c0e504b81391c4033f33ab99aa439dff2560e53"
SDL_AUDIO_PATCH_SHA256="85be95846d9365e9c06049af2f4a82f02d5c3101fedcd109cfa6f0a513659b2b"
STRCHRNUL_PATCH_SHA256="ec1048dd0e8ebe53bf7e8a3bca9bf2f5f4336cd607d4cd077437470e9a32094a"
VIRTFS_OWNER_PATCH_SHA256="9748b0c223f0bc8c649d8b7c5c5e574f94e91d5411f9606ef9159c3bb6cd631b"

BREW_PREFIX="$(brew --prefix)"
EPOXY="${BREW_PREFIX}/opt/libepoxy-angle"
VIRGL="${BREW_PREFIX}/opt/virglrenderer"
ANGLE="${BREW_PREFIX}/opt/libangle"
LIBPNG="${BREW_PREFIX}/opt/libpng"

[[ -f ${PINNED_SDL} && ! -L ${PINNED_SDL} ]] || {
  echo "error: pinned SDL manifest missing: ${PINNED_SDL}" >&2
  exit 1
}
# shellcheck source=scripts/pinned-sdl-runtime.sh
source "${PINNED_SDL}"
SDL_DEPENDENCIES="${STATE}/sdl-runtime"
SDL2="${SDL_DEPENDENCIES}/${BENTO_SDL2_ROOT}"
SDL3="${SDL_DEPENDENCIES}/${BENTO_SDL3_ROOT}"

BINARY="${PREFIX}/bin/qemu-system-aarch64"

CLEAN=0
CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── report ────────────────────────────────────────────────────────────────────
report() {
  if [[ ! -x ${BINARY} ]]; then
    echo "not built — run ./scripts/build-qemu-gl.sh"
    return 1
  fi
  echo "binary     ${BINARY}"
  local device_help fsdev_help gl entitled audio_entitled hvf_probe version runtime_library failed=0
  version="$("${BINARY}" --version | head -1)"
  if [[ ${version} == "QEMU emulator version ${QEMU_VERSION}"* ]]; then
    echo "version    ${version}"
  else
    echo "version    ${version} — expected ${QEMU_VERSION}"
    failed=1
  fi
  gl="$("${BINARY}" -device help 2>/dev/null | grep -c 'virtio-gpu-gl-pci' || true)"
  if [[ ${gl} -gt 0 ]]; then
    echo "virtio-gpu-gl-pci  present"
  else
    echo "virtio-gpu-gl-pci  MISSING — the build did not pick up virglrenderer"
    failed=1
  fi
  device_help="$("${BINARY}" -device help 2>/dev/null)"
  for device in virtio-keyboard-pci virtio-tablet-pci virtio-rng-pci \
                virtio-serial-pci virtio-9p-pci; do
    if [[ ${device_help} != *"${device}"* ]]; then
      echo "${device}  MISSING"
      failed=1
    fi
  done
  if [[ ${failed} -eq 0 ]]; then
    echo "virtio input, serial, RNG, and 9p  present"
  fi
  local audio_help
  audio_help="$("${BINARY}" -machine virt -audiodev help 2>&1 || true)"
  if [[ ${audio_help} == "sdl" || ${audio_help} == *$'\nsdl\n'* \
      || ${audio_help} == sdl$'\n'* || ${audio_help} == *$'\nsdl' ]]; then
    echo "SDL duplex audio  present"
  else
    echo "SDL duplex audio  MISSING"
    failed=1
  fi
  fsdev_help="$("${BINARY}" -fsdev local,help 2>&1 || true)"
  if [[ ${fsdev_help} == *"uid=<num>"* && ${fsdev_help} == *"gid=<num>"* ]]; then
    echo "9p guest owner mapping  present"
  else
    echo "9p guest owner mapping  MISSING"
    failed=1
  fi
  if otool -L "${BINARY}" | grep -qi 'libpng'; then
    echo "QMP PNG screenshots  present"
  else
    echo "QMP PNG screenshots  MISSING"
    failed=1
  fi
  if strings "${BINARY}" | grep -F 'isKeyboardCaptured' >/dev/null; then
    echo "focused Cmd forward present"
  else
    echo "focused Cmd forward MISSING — ordinary Cmd chords follow the mouse grab"
    failed=1
  fi
  if strings "${BINARY}" | grep -F 'windowDidChangeBackingProperties:' >/dev/null; then
    echo "dynamic Retina display present"
  else
    echo "dynamic Retina display MISSING — window geometry will not reach virtio-gpu EDID"
    failed=1
  fi
  if strings "${BINARY}" | grep -F 'immersive' >/dev/null; then
    echo "immersive Cocoa mode present"
  else
    echo "immersive Cocoa mode MISSING"
    failed=1
  fi
  if strings "${BINARY}" | grep -F 'Bento Command-Space capture enabled' >/dev/null; then
    echo "Carbon Cmd+Space bridge present"
  else
    echo "Carbon Cmd+Space bridge MISSING — Spotlight will keep the shortcut"
    failed=1
  fi
  if strings "${BINARY}" | grep -F 'BENTO_SDL_AUDIO_CONTROL_DIRECTORY' >/dev/null; then
    echo "live SDL audio routing present"
  else
    echo "live SDL audio routing MISSING"
    failed=1
  fi
  if otool -L "${BINARY}" | grep -F 'libSDL2-2.0.0.dylib' >/dev/null; then
    echo "SDL2-compat runtime linked"
  else
    echo "SDL2-compat runtime MISSING"
    failed=1
  fi
  for runtime_library in "${PREFIX}/lib/libSDL2-2.0.0.dylib" \
                         "${PREFIX}/lib/libSDL3.dylib"; do
    if [[ ! -f ${runtime_library} ]] \
        || ! codesign --verify --strict "${runtime_library}" 2>/dev/null; then
      echo "$(basename "${runtime_library}") signature  MISSING or invalid"
      failed=1
    fi
  done
  # `-display help` prints the backend list, then a blank line and two paragraphs of
  # prose about suboptions. Stop at the blank line or the prose comes with it.
  echo "displays   $("${BINARY}" -display help 2>/dev/null |
                       awk 'NR>1 { if (!NF) exit; print }' | tr '\n' ' ')"
  if codesign -d --entitlements - "${BINARY}" 2>&1 | grep -q 'com.apple.security.hypervisor'; then
    entitled="yes"
  else
    entitled="NO — hvf will be refused"
    failed=1
  fi
  echo "hypervisor entitlement  ${entitled}"
  if codesign -d --entitlements - "${BINARY}" 2>&1 | grep -q 'com.apple.security.device.audio-input'; then
    audio_entitled="yes"
  else
    audio_entitled="NO — microphone capture will be refused"
    failed=1
  fi
  echo "audio-input entitlement  ${audio_entitled}"
  if [[ ${entitled} == yes ]]; then
    hvf_probe="$(printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' |
      "${BINARY}" -name bento-hvf-probe -machine virt,accel=hvf,gic-version=3 \
        -cpu host,pmu=off -nodefaults -display none -S -qmp stdio 2>&1)" || true
    if [[ ${hvf_probe} == *'"QMP"'* && ${hvf_probe} != *'"error"'* ]]; then
      echo "HVF GICv3 probe  passed"
    else
      echo "HVF GICv3 probe  FAILED"
      failed=1
    fi
  fi
  return "${failed}"
}

if [[ ${CHECK} -eq 1 ]]; then
  report
  exit $?
fi

# ── dependencies ──────────────────────────────────────────────────────────────
missing=()
for dep in "${EPOXY}" "${VIRGL}" "${ANGLE}" "${LIBPNG}"; do
  [[ -d ${dep} ]] || missing+=("$(basename "${dep}")")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  cat >&2 <<EOF
error: missing GL dependencies: ${missing[*]}

Install them (bottled, ~18 MiB, pulls only rapidjson + spice-protocol):

  brew tap startergo/qemu-virgl
  brew trust startergo/qemu-virgl
  brew install startergo/qemu-virgl/virglrenderer

To undo everything this script needs:
  brew uninstall virglrenderer libepoxy-angle libangle && brew untap startergo/qemu-virgl
EOF
  exit 1
fi

for tool in meson ninja pkg-config; do
  command -v "${tool}" >/dev/null || { echo "error: ${tool} not found — brew install meson ninja pkg-config" >&2; exit 1; }
done

verify_patch() {
  local patch_path="$1" expected_sha256="$2"
  if [[ ! -f ${patch_path} ]]; then
    echo "error: patch missing: ${patch_path}" >&2
    exit 1
  fi
  if [[ "$(shasum -a 256 "${patch_path}" | cut -d' ' -f1)" != "${expected_sha256}" ]]; then
    echo "error: ${patch_path} does not match its pinned sha256" >&2
    exit 1
  fi
}

verify_patch "${VIRGL_PATCH}" "${VIRGL_PATCH_SHA256}"
verify_patch "${GPU_DIRTY_PATCH}" "${GPU_DIRTY_PATCH_SHA256}"
verify_patch "${DYNAMIC_DISPLAY_PATCH}" "${DYNAMIC_DISPLAY_PATCH_SHA256}"
verify_patch "${IMMERSIVE_PATCH}" "${IMMERSIVE_PATCH_SHA256}"
verify_patch "${FULL_GRAB_PATCH}" "${FULL_GRAB_PATCH_SHA256}"
verify_patch "${COMMAND_SPACE_PATCH}" "${COMMAND_SPACE_PATCH_SHA256}"
verify_patch "${PAUSE_OWNERSHIP_PATCH}" "${PAUSE_OWNERSHIP_PATCH_SHA256}"
verify_patch "${SDL_AUDIO_PATCH}" "${SDL_AUDIO_PATCH_SHA256}"
verify_patch "${STRCHRNUL_PATCH}" "${STRCHRNUL_PATCH_SHA256}"
verify_patch "${VIRTFS_OWNER_PATCH}" "${VIRTFS_OWNER_PATCH_SHA256}"

# ── source ────────────────────────────────────────────────────────────────────
mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"

obtain_and_verify() {
  local label="$1" filename="$2" url="$3" expected_sha256="$4"
  if [[ ! -f ${filename} ]]; then
    echo "==> Downloading ${label}"
    curl --fail --location --silent --show-error --retry 3 \
      --output "${filename}" "${url}"
  fi
  if [[ "$(shasum -a 256 "${filename}" | cut -d' ' -f1)" != "${expected_sha256}" ]]; then
    echo "error: ${filename} does not match its pinned sha256 — delete it and retry" >&2
    exit 1
  fi
}

obtain_and_verify "QEMU ${QEMU_VERSION} (~135 MiB)" "${QEMU_TARBALL}" "${QEMU_URL}" "${QEMU_SHA256}"
obtain_and_verify "QEMU device-tree compiler source" "${DTC_TARBALL}" "${DTC_URL}" "${DTC_SHA256}"
obtain_and_verify "setuptools build wheel" "${SETUPTOOLS_WHEEL}" "${SETUPTOOLS_URL}" "${SETUPTOOLS_SHA256}"
obtain_and_verify "wheel build wheel" "${WHEEL_WHEEL}" "${WHEEL_URL}" "${WHEEL_SHA256}"
obtain_and_verify "pip build wheel" "${PIP_WHEEL}" "${PIP_URL}" "${PIP_SHA256}"

TREE="${SRC_DIR}/qemu-${QEMU_VERSION}"
if [[ ${CLEAN} -eq 1 ]]; then
  rm -rf "${TREE}"
fi

if [[ -d ${TREE} && ! -f ${TREE}/.bento-audio-sleep-patches ]]; then
  echo "error: the existing QEMU source predates Bento's audio and sleep patches" >&2
  echo "       rebuild it with: ./scripts/build-qemu-gl.sh --clean" >&2
  exit 1
fi

if [[ ! -d ${TREE} ]]; then
  echo "==> Unpacking"
  tar xf "${QEMU_TARBALL}"
  install -m 0644 "${SETUPTOOLS_WHEEL}" "${WHEEL_WHEEL}" "${PIP_WHEEL}" \
    "${TREE}/python/wheels/"
  mkdir -p "${TREE}/subprojects/dtc"
  tar -xzf "${DTC_TARBALL}" -C "${TREE}/subprojects/dtc" --strip-components=1
  echo "==> Applying $(basename "${VIRGL_PATCH}")"
  # --forward makes a re-run a no-op rather than an offer to reverse the patch.
  patch -p1 -d "${TREE}" --batch --forward < "${VIRGL_PATCH}"
  echo "==> Applying $(basename "${GPU_DIRTY_PATCH}")"
  patch -p1 -d "${TREE}" --batch --forward < "${GPU_DIRTY_PATCH}"
  echo "==> Applying $(basename "${DYNAMIC_DISPLAY_PATCH}")"
  patch -p1 -d "${TREE}" --batch --forward < "${DYNAMIC_DISPLAY_PATCH}"
  echo "==> Applying $(basename "${IMMERSIVE_PATCH}")"
  patch -p1 -d "${TREE}" --batch --forward < "${IMMERSIVE_PATCH}"
  echo "==> Applying $(basename "${FULL_GRAB_PATCH}")"
  patch -p1 -d "${TREE}" --batch --forward < "${FULL_GRAB_PATCH}"
  echo "==> Applying $(basename "${COMMAND_SPACE_PATCH}")"
  patch -p1 -d "${TREE}" --batch --forward < "${COMMAND_SPACE_PATCH}"
  echo "==> Applying $(basename "${PAUSE_OWNERSHIP_PATCH}")"
  patch -p1 -d "${TREE}" --batch --forward < "${PAUSE_OWNERSHIP_PATCH}"
  echo "==> Applying $(basename "${SDL_AUDIO_PATCH}")"
  patch -p1 -d "${TREE}" --batch --forward < "${SDL_AUDIO_PATCH}"
  echo "==> Applying $(basename "${STRCHRNUL_PATCH}")"
  patch -p1 -d "${TREE}" --batch --forward < "${STRCHRNUL_PATCH}"
  echo "==> Applying $(basename "${VIRTFS_OWNER_PATCH}")"
  patch -p1 -d "${TREE}" --batch --forward < "${VIRTFS_OWNER_PATCH}"
  touch "${TREE}/.bento-virtfs-owner-patch"
  touch "${TREE}/.bento-audio-sleep-patches"
fi

# ── configure + build ─────────────────────────────────────────────────────────
bento_sdl_prepare "${SRC_DIR}" "${SDL_DEPENDENCIES}"
# Homebrew's relocatable bottle keeps placeholders in this compatibility
# package's pkg-config file. Resolve them only inside Bento's pinned copy.
sed -i '' \
  -e "s|^prefix=@@HOMEBREW_PREFIX@@$|prefix=${SDL2}|" \
  -e "s|^libdir=@@HOMEBREW_PREFIX@@/lib$|libdir=${SDL2}/lib|" \
  -e "s|^includedir=@@HOMEBREW_PREFIX@@/include$|includedir=${SDL2}/include|" \
  "${SDL2}/lib/pkgconfig/sdl2-compat.pc"
# sdl2-compat loads SDL3 by this exact @loader_path name.
install -m 0755 "${SDL3}/lib/libSDL3.0.dylib" "${SDL2}/lib/libSDL3.dylib"
export PKG_CONFIG_PATH="${VIRGL}/lib/pkgconfig:${EPOXY}/lib/pkgconfig:${LIBPNG}/lib/pkgconfig:${SDL2}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export DYLD_LIBRARY_PATH="${SDL2}/lib:${SDL3}/lib:${DYLD_LIBRARY_PATH:-}"

BUILD="${TREE}/build"
mkdir -p "${BUILD}"
cd "${BUILD}"

if [[ ! -f build.ninja ]]; then
  echo "==> Configuring"
  # Only aarch64-softmmu: this host runs one guest architecture and every extra
  # target is minutes of compile for a binary nothing will launch.
  #
  # --disable-spice is the whole reason we build instead of pouring the tap's bottle.
  # --enable-slirp keeps the user-mode netdev that run-vm.sh forwards ssh over.
  #
  # The ANGLE include path is NOT optional and pkg-config will not supply it: epoxy's
  # own egl_generated.h does `#include "EGL/eglplatform.h"`, and that header ships with
  # ANGLE, not with epoxy. Without it the build dies only when it reaches ui/cocoa.m,
  # about 1500 objects in.
  ../configure \
    --prefix="${PREFIX}" \
    --target-list=aarch64-softmmu \
    --without-default-features \
    --enable-system \
    --enable-cocoa \
    --enable-opengl \
    --enable-virglrenderer \
    --enable-hvf \
    --disable-tcg \
    --enable-pixman \
    --enable-slirp \
    --enable-virtfs \
    --enable-png \
    --enable-fdt=internal \
    --disable-spice \
    --disable-gtk \
    --enable-sdl \
    --audio-drv-list=sdl \
    --disable-vnc \
    --disable-guest-agent \
    --disable-docs \
    --disable-download \
    --disable-werror \
    --extra-cflags="-I${ANGLE}/include" \
    --extra-ldflags="-L${ANGLE}/lib" \
    --extra-ldflags="-Wl,-rpath,${ANGLE}/lib" \
    --extra-ldflags="-Wl,-rpath,${EPOXY}/lib" \
    --extra-ldflags="-Wl,-rpath,${VIRGL}/lib"
elif grep -q '^#undef CONFIG_PNG' config-host.h 2>/dev/null; then
  echo "error: the existing QEMU build predates PNG screenshot support" >&2
  echo "       rebuild it with: ./scripts/build-qemu-gl.sh --clean" >&2
  exit 1
fi

echo "==> Building (this takes a few minutes)"
ninja

echo "==> Installing to ${PREFIX}"
rm -rf "${PREFIX}"
ninja install

# Homebrew bottles carry placeholder install names that are normally rewritten by
# Homebrew during installation. Bento deliberately uses checksum-pinned, private
# copies instead, so make the installed QEMU runtime self-contained and relocatable.
QEMU_RUNTIME_LIB="${PREFIX}/lib"
QEMU_SDL2="${QEMU_RUNTIME_LIB}/libSDL2-2.0.0.dylib"
QEMU_SDL3="${QEMU_RUNTIME_LIB}/libSDL3.dylib"
mkdir -p "${QEMU_RUNTIME_LIB}"
install -m 0755 "${SDL2}/lib/libSDL2-2.0.0.dylib" "${QEMU_SDL2}"
install -m 0755 "${SDL2}/lib/libSDL3.dylib" "${QEMU_SDL3}"
xattr -c "${QEMU_SDL2}" "${QEMU_SDL3}"
install_name_tool -id '@loader_path/libSDL2-2.0.0.dylib' "${QEMU_SDL2}"
install_name_tool -id '@loader_path/libSDL3.dylib' "${QEMU_SDL3}"
SDL2_BUILD_LINK="$(otool -L "${BINARY}" | awk '/libSDL2-2\.0\.0\.dylib/ {print $1; exit}')"
if [[ -z ${SDL2_BUILD_LINK} ]]; then
  echo "error: installed QEMU has no SDL2-compat dependency" >&2
  exit 1
fi
install_name_tool -change "${SDL2_BUILD_LINK}" \
  '@loader_path/../lib/libSDL2-2.0.0.dylib' "${BINARY}"

# ── code signing ──────────────────────────────────────────────────────────────
# QEMU's install hook signs for HVF and attaches an obsolete resource fork.
# Clear only that metadata, then replace the signature with Bento's superset:
# hardware virtualization plus on-demand microphone capture.
echo "==> Signing QEMU for HVF and optional microphone capture"
xattr -c "${BINARY}"
codesign --force --sign - "${QEMU_SDL3}"
codesign --force --sign - "${QEMU_SDL2}"
codesign --force --sign - --entitlements "${QEMU_ENTITLEMENTS}" "${BINARY}"
if ! codesign -d --entitlements - "${BINARY}" 2>&1 \
    | grep -q 'com.apple.security.hypervisor'; then
  echo "error: ${BINARY} has no hypervisor entitlement" >&2
  exit 1
fi
if ! codesign -d --entitlements - "${BINARY}" 2>&1 \
    | grep -q 'com.apple.security.device.audio-input'; then
  echo "error: ${BINARY} has no audio-input entitlement" >&2
  exit 1
fi

echo
report
