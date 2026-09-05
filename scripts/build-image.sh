#!/usr/bin/env bash
# bento — build the aarch64 NixOS image and stage a writable copy for run-vm.sh.
#
#   ./scripts/build-image.sh            # build, then replace artifacts/bento.qcow2
#   ./scripts/build-image.sh --keep     # build, but refuse to clobber an existing disk
#   ./scripts/build-image.sh --size 80G # stage at a different disk size (default 60G)
#
# Needs the aarch64-linux builder running:  ./scripts/start-linux-builder.sh
#
# The store output is read-only and sized to the closure. What the VM actually boots is
# the copy under artifacts/: writable, and resized so the guest's growPartition +
# autoResize can expand the root filesystem into it on first boot.

set -euo pipefail
umask 077

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="${REPO_ROOT}/artifacts"
DISK="${ARTIFACTS}/bento.qcow2"
FLAKE_ATTR=".#packages.aarch64-linux.bento-image"

DISK_SIZE="60G"
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --size) DISK_SIZE="${2:?--size needs an argument}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Nix is not on a non-interactive shell's PATH on this host.
# shellcheck disable=SC1091
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true

if ! command -v nix >/dev/null 2>&1; then
  echo "error: nix not found on PATH" >&2
  exit 1
fi

if [[ ${KEEP} -eq 1 && -e ${DISK} ]]; then
  echo "error: ${DISK} exists and --keep was given" >&2
  exit 1
fi

if ! /usr/bin/nc -z localhost 31022 >/dev/null 2>&1; then
  echo "error: the aarch64-linux builder is not reachable on localhost:31022." >&2
  echo "       start it first:  ./scripts/start-linux-builder.sh" >&2
  exit 1
fi

cd "${REPO_ROOT}"

echo "==> Building ${FLAKE_ATTR} (on the linux builder; expect this to take a while)"
out="$(nix build "${FLAKE_ATTR}" --no-link --print-out-paths --print-build-logs)"

# The image module names the file after the NixOS label, so glob rather than guess.
src="$(find "${out}" -maxdepth 1 -name '*.qcow2' -print -quit)"
if [[ -z ${src} ]]; then
  echo "error: no .qcow2 found in ${out}" >&2
  exit 1
fi

echo "==> Built ${src}"

mkdir -p "${ARTIFACTS}"
chmod 0700 "${ARTIFACTS}"
rm -f "${DISK}"
cp "${src}" "${DISK}"
chmod u+w "${DISK}"
chmod 0600 "${DISK}"

echo "==> Resizing writable copy to ${DISK_SIZE}"
qemu-img resize "${DISK}" "${DISK_SIZE}"

echo
qemu-img info "${DISK}"
echo
echo "==> Ready: ${DISK}"
echo "    boot it with:  ./scripts/run-vm.sh"
