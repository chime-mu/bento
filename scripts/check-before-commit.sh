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
require_command python3

run_check "Checking staged and unstaged diffs for whitespace errors" \
  git diff HEAD --check

run_check "Checking shell script syntax" \
  find scripts tests home hosts -type f -name '*.sh' -exec bash -n {} +

run_check "Running portable test suite" \
  env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'

if [[ "$(uname -s)" == "Darwin" ]]; then
  run_check "Running macOS integration tests" \
    ./tests/test_macos.sh
else
  echo "==> Skipping macOS integration tests on $(uname -s)"
fi

# Use a path flake so newly-created files are included before their first commit.
# --no-build validates every output without attempting the full qcow2 image build.
run_check "Evaluating all Nix flake outputs" \
  nix flake check path:. --all-systems --no-build

echo "All pre-commit checks passed."
