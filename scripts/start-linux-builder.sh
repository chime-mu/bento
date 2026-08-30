#!/usr/bin/env bash
# bento — start the aarch64-linux builder VM. NO sudo required.
#
#   ./scripts/start-linux-builder.sh          # run in foreground
#   ./scripts/start-linux-builder.sh --check  # just report whether it's reachable
#
# Requires ./scripts/setup-linux-builder.sh to have been run once (as root).
#
# The builder VM listens on localhost:31022. Its 20 GB disk image and SSH keypair live
# under ~/.local/state/bento so they survive across runs and stay out of the repo.
# Stop the VM with `shutdown now` at its `builder@nixos` prompt, or kill this process.

set -euo pipefail

STATE_DIR="${HOME}/.local/state/bento"
export KEYS="${STATE_DIR}/builder-keys"
export NIX_DISK_IMAGE="${STATE_DIR}/builder-disk.qcow2"

builder_is_up() {
  # -G parses config and exits; we want a real connection test, so use nc-style probe.
  /usr/bin/nc -z localhost 31022 >/dev/null 2>&1
}

if [[ ${1:-} == "--check" ]]; then
  if builder_is_up; then
    echo "builder: UP (localhost:31022)"
    exit 0
  fi
  echo "builder: DOWN"
  exit 1
fi

if [[ ! -d ${KEYS} ]]; then
  echo "error: ${KEYS} missing — run: sudo ./scripts/setup-linux-builder.sh" >&2
  exit 1
fi

if builder_is_up; then
  echo "builder already running on localhost:31022 — nothing to do"
  exit 0
fi

mkdir -p "${STATE_DIR}"

# shellcheck disable=SC1091
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true

echo "==> Starting linux-builder VM (disk: ${NIX_DISK_IMAGE})"
echo "    first boot creates a 20 GB image; this takes a moment"
exec nix run nixpkgs#darwin.linux-builder
