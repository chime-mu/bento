#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${REPO_ROOT}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

run_check() {
  local description="$1"
  shift

  echo "==> ${description}"
  "$@"
}

require_command bash
require_command git
require_command nix

run_check "Checking staged and unstaged diffs for whitespace errors" \
  git diff HEAD --check

run_check "Checking shell script syntax" \
  find scripts tests home hosts -type f -name '*.sh' -exec bash -n {} +

# **tests/ is two suites, not one, and which machine you are on decides which runs.**
#
# There is no portable half. `tests/test_run_vm.py` drives `scripts/run-vm.sh`, which
# boots QEMU on the Apple Silicon host, and `tests/test_vm_screenshot.py` drives
# `scripts/vm-screenshot.sh`, which photographs the guest over QMP from outside it.
# Neither describes anything this guest can be right or wrong about: the machine here is
# a NixOS configuration, and QEMU is the host's job.
#
# They also cannot pass here, for reasons that are about the machine and not the code —
# both reach for `/usr/bin/python3`, which macOS ships and NixOS has no directory for,
# and run-vm.sh builds its variable store with BSD `dd bs=1m` that GNU dd rejects. Those
# spellings are correct on the host they run on; making them portable would be churn in
# the script that boots the VM, in exchange for tests that still prove nothing about the
# host from in here.
#
# So the guest runs the guest's tests, which are the flake checks below, and the host
# runs the host's.
if [[ "$(uname -s)" == "Darwin" ]]; then
  require_command python3

  run_check "Running host-side test suite" \
    env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'

  run_check "Running macOS integration tests" \
    ./tests/test_macos.sh
else
  echo "==> Skipping host-side tests on $(uname -s) — they drive the macOS QEMU launcher"
fi

# Use a path flake so newly-created files are included before their first commit.
# --no-build validates every output without attempting the full qcow2 image build.
run_check "Evaluating all Nix flake outputs" \
  nix flake check path:. --all-systems --no-build

# **`--no-build` above only evaluates.** It proves every output *resolves* — that the
# NixOS configuration and both images are buildable expressions — but it stops at the
# derivation and never runs one, so on its own it would report success without having
# executed a single test.
#
# `checks` is defined for aarch64-linux only (flake.nix), and it is exactly the guest's
# suite: test_display_sync, test_clipboard_agent, test_audio_agent and test_mount_mac,
# each in a sandbox with its own pkgs.python3 — which is why this step needs no
# interpreter on PATH. Building them is what makes them run.
if [[ "$(uname -s)" != "Darwin" ]]; then
  run_check "Running the guest test suite (flake checks)" \
    nix build --no-link path:.#checks.aarch64-linux.display-sync \
      path:.#checks.aarch64-linux.clipboard-agent \
      path:.#checks.aarch64-linux.audio-agent \
      path:.#checks.aarch64-linux.mount-mac
else
  echo "==> Skipping guest flake checks on Darwin (aarch64-linux; needs a linux builder)"
fi

echo "All pre-commit checks passed."
