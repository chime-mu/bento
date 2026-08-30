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
#   3. the patch      — scripts/patches/qemu-10.1-macos-virgl.patch, akihikodaki's
#                       macOS VirGL series. It decouples CONFIG_EGL from CONFIG_OPENGL
#                       (macOS has GL but no EGL, and stock meson.build assumes that is
#                       impossible), adds OpenGL to cocoa's framework list, and teaches
#                       virtio-gpu to borrow virglrenderer's scanout texture.
#
# We build rather than pouring the tap's `qemu-virgl` bottle because that bottle links
# libspice-server, and spice-server pulls gstreamer and ~60 further formulae onto the
# host, plus upgrades of 20 unrelated ones. `--disable-spice` costs a compile and
# nothing else: every remaining dependency was already installed for Homebrew's qemu.
#
# Code signing is not optional — but it is also not ours to do. macOS gates hardware
# virtualization behind the com.apple.security.hypervisor entitlement, and without it
# `-machine virt,accel=hvf` is refused. PLAN-v1 §6 and learned/phase-0.md §2 both expect
# us to sign the binary; **QEMU signs itself**. `make install` runs
# scripts/entitlement.sh with accel/hvf/entitlements.plist, so the step below is a check.
#
# Do not "fix" it into a real signing step. entitlement.sh also attaches pc-bios/qemu.rsrc
# as a resource fork, and codesign refuses to re-sign a binary carrying one:
# "resource fork, Finder information, or similar detritus not allowed".

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${HOME}/.local/state/bento"
SRC_DIR="${STATE}/qemu-gl-src"
PREFIX="${STATE}/qemu-gl"
PATCH="${REPO_ROOT}/scripts/patches/qemu-10.1-macos-virgl.patch"

QEMU_VERSION="10.1.2"
QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TARBALL}"
# Both digests are pinned: the tarball because it comes off the network, and the patch
# because it was fetched from a *branch* URL in the startergo tap, which can move.
QEMU_SHA256="9d75f331c1a5cb9b6eb8fd9f64f563ec2eab346c822cb97f8b35cd82d3f11479"
PATCH_SHA256="d0da295f24ece630f82e685ffa571ce02f11d31f8311942bc0b50d1430f3323a"

BREW_PREFIX="$(brew --prefix)"
EPOXY="${BREW_PREFIX}/opt/libepoxy-angle"
VIRGL="${BREW_PREFIX}/opt/virglrenderer"
ANGLE="${BREW_PREFIX}/opt/libangle"

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
  echo "version    $("${BINARY}" --version | head -1)"
  local gl entitled
  gl="$("${BINARY}" -device help 2>/dev/null | grep -c 'virtio-gpu-gl-pci' || true)"
  if [[ ${gl} -gt 0 ]]; then
    echo "virtio-gpu-gl-pci  present"
  else
    echo "virtio-gpu-gl-pci  MISSING — the build did not pick up virglrenderer"
  fi
  # `-display help` prints the backend list, then a blank line and two paragraphs of
  # prose about suboptions. Stop at the blank line or the prose comes with it.
  echo "displays   $("${BINARY}" -display help 2>/dev/null |
                       awk 'NR>1 { if (!NF) exit; print }' | tr '\n' ' ')"
  if codesign -d --entitlements - "${BINARY}" 2>&1 | grep -q 'com.apple.security.hypervisor'; then
    entitled="yes"
  else
    entitled="NO — hvf will be refused"
  fi
  echo "hypervisor entitlement  ${entitled}"
}

if [[ ${CHECK} -eq 1 ]]; then
  report
  exit $?
fi

# ── dependencies ──────────────────────────────────────────────────────────────
missing=()
for dep in "${EPOXY}" "${VIRGL}" "${ANGLE}"; do
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

if [[ ! -f ${PATCH} ]]; then
  echo "error: patch missing: ${PATCH}" >&2
  exit 1
fi
if [[ "$(shasum -a 256 "${PATCH}" | cut -d' ' -f1)" != "${PATCH_SHA256}" ]]; then
  echo "error: ${PATCH} does not match its pinned sha256" >&2
  exit 1
fi

# ── source ────────────────────────────────────────────────────────────────────
mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"

if [[ ! -f ${QEMU_TARBALL} ]]; then
  echo "==> Downloading QEMU ${QEMU_VERSION} (~135 MiB)"
  curl -fSL --progress-bar -o "${QEMU_TARBALL}" "${QEMU_URL}"
fi
if [[ "$(shasum -a 256 "${QEMU_TARBALL}" | cut -d' ' -f1)" != "${QEMU_SHA256}" ]]; then
  echo "error: ${QEMU_TARBALL} does not match its pinned sha256 — delete it and retry" >&2
  exit 1
fi

TREE="${SRC_DIR}/qemu-${QEMU_VERSION}"
if [[ ${CLEAN} -eq 1 ]]; then
  rm -rf "${TREE}"
fi

if [[ ! -d ${TREE} ]]; then
  echo "==> Unpacking"
  tar xf "${QEMU_TARBALL}"
  echo "==> Applying $(basename "${PATCH}")"
  # --forward makes a re-run a no-op rather than an offer to reverse the patch.
  patch -p1 -d "${TREE}" --batch --forward < "${PATCH}"
fi

# ── configure + build ─────────────────────────────────────────────────────────
export PKG_CONFIG_PATH="${VIRGL}/lib/pkgconfig:${EPOXY}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

BUILD="${TREE}/build"
mkdir -p "${BUILD}"
cd "${BUILD}"

if [[ ! -f build.ninja ]]; then
  echo "==> Configuring"
  # Only aarch64-softmmu: this host runs one guest architecture and every extra
  # target is minutes of compile for a binary nothing will launch.
  #
  # --disable-spice is the whole reason we build instead of pouring the tap's bottle.
  # --enable-slirp keeps the `-nic user,hostfwd=` that run-vm.sh forwards ssh over.
  #
  # The ANGLE include path is NOT optional and pkg-config will not supply it: epoxy's
  # own egl_generated.h does `#include "EGL/eglplatform.h"`, and that header ships with
  # ANGLE, not with epoxy. Without it the build dies only when it reaches ui/cocoa.m,
  # about 1500 objects in.
  ../configure \
    --prefix="${PREFIX}" \
    --target-list=aarch64-softmmu \
    --enable-cocoa \
    --enable-opengl \
    --enable-virglrenderer \
    --enable-hvf \
    --enable-slirp \
    --enable-curses \
    --disable-spice \
    --disable-gtk \
    --disable-sdl \
    --disable-vnc \
    --disable-guest-agent \
    --disable-docs \
    --extra-cflags="-I${ANGLE}/include" \
    --extra-ldflags="-L${ANGLE}/lib" \
    --extra-ldflags="-Wl,-rpath,${ANGLE}/lib" \
    --extra-ldflags="-Wl,-rpath,${EPOXY}/lib" \
    --extra-ldflags="-Wl,-rpath,${VIRGL}/lib"
fi

echo "==> Building (this takes a few minutes)"
ninja

echo "==> Installing to ${PREFIX}"
rm -rf "${PREFIX}"
ninja install

# ── code signing ──────────────────────────────────────────────────────────────
# Without com.apple.security.hypervisor, `-machine virt,accel=hvf` is refused by the
# kernel and the VM will not start. PLAN-v1 §6 and learned/phase-0.md §2 both flag this
# as a step we would have to perform ourselves — we do not.
#
# QEMU signs itself. `make install` runs scripts/entitlement.sh, which ad-hoc signs the
# binary with accel/hvf/entitlements.plist. So this is a *check*, not a signing step,
# and re-signing here is actively wrong: entitlement.sh also attaches pc-bios/qemu.rsrc
# as a resource fork, and a second `codesign --force` rejects it outright with
# "resource fork, Finder information, or similar detritus not allowed".
echo "==> Verifying the hvf entitlement"
if codesign -d --entitlements - "${BINARY}" 2>&1 | grep -q 'com.apple.security.hypervisor'; then
  echo "    ok — signed by QEMU's own entitlement.sh"
else
  echo "error: ${BINARY} has no com.apple.security.hypervisor entitlement." >&2
  echo "       hvf will be refused. Sign it by hand with:" >&2
  echo "         codesign --sign - --force \\" >&2
  echo "           --entitlements ${TREE}/accel/hvf/entitlements.plist ${BINARY}" >&2
  exit 1
fi

echo
report
