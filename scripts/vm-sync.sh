#!/usr/bin/env bash
# bento — move commits between this repo and the copy inside the VM.
#
#   ./scripts/vm-sync.sh init     # create ~/bento in the VM and add the `vm` remote here
#   ./scripts/vm-sync.sh push     # this repo  ->  the VM's working tree
#   ./scripts/vm-sync.sh pull     # the VM     ->  this repo
#   ./scripts/vm-sync.sh status   # who is ahead of whom
#
# The VM must be running (./scripts/run-vm.sh --headless).
#
# Why git and not a 9p share of this directory — the question Phase 1 left open:
#
#   This host's QEMU *does* support 9p (`-fsdev local,security_model=none` initialises
#   fine on 11.1.1), so sharing /Users/chime/Workspace/Bento straight into the guest was a
#   real option. It was rejected. `security_model=none` passes host uids through
#   unmapped, so the repo arrives owned by uid 501 with no matching guest account, and
#   anything the guest writes lands on the Mac owned by uid 1000; every `nixos-rebuild`
#   would also drag the whole tree across 9p into the store. More importantly it makes the
#   guest's configuration depend on a macOS path, which is exactly the coupling that has
#   to be undone when bento moves to bare metal.
#
#   So: two real git repositories, and history is the thing that moves between them.
#
# Both directions are initiated *from the host*, because only that direction works.
# `-nic user` gives the guest NAT, and macOS runs no ssh server by default, so the guest
# cannot reach this repo — but the host reaches the guest on the 2222 forward. `push`
# therefore relies on `receive.denyCurrentBranch=updateInstead` in the guest repo, which
# `init` sets: a push updates the checked-out working tree, and is refused outright if
# that tree is dirty. Nothing is ever silently overwritten in either direction.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

SSH_PORT="2222"
VM_USER="chime"
VM_PATH="/home/chime/bento"
REMOTE_NAME="vm"

# A dev VM on the host's own loopback, whose host key legitimately changes every time the
# image is rebuilt. Pinning it would mean teaching the user to clear a
# REMOTE HOST IDENTIFICATION HAS CHANGED warning after each re-image, so it is not pinned
# — the same trust posture Phase 0 accepted for the linux-builder's publicly-known key.
ssh_opts() {
  printf '%s' "-p ${SSH_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
}

usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

vm_ssh() {
  # shellcheck disable=SC2046  # word splitting of the option list is intended
  ssh $(ssh_opts) "${VM_USER}@localhost" "$@"
}

require_vm() {
  if ! /usr/bin/nc -z localhost "${SSH_PORT}" >/dev/null 2>&1; then
    echo "error: nothing listening on localhost:${SSH_PORT} — is the VM up?" >&2
    echo "       start it with:  ./scripts/run-vm.sh --headless" >&2
    exit 1
  fi
  if ! vm_ssh true >/dev/null 2>&1; then
    echo "error: the port is open but ssh to ${VM_USER}@localhost:${SSH_PORT} failed." >&2
    echo "       the guest may still be booting — try again in a moment." >&2
    exit 1
  fi
}

# git talks to the VM over the same unpinned ssh; exported so `git push`/`fetch` inherit it.
setup_git_ssh() {
  GIT_SSH_COMMAND="ssh $(ssh_opts)"
  export GIT_SSH_COMMAND
}

remote_url() { printf 'ssh://%s@localhost%s' "${VM_USER}" "${VM_PATH}"; }

cmd_init() {
  require_vm
  cd "${REPO_ROOT}"

  if vm_ssh "test -e ${VM_PATH}/.git"; then
    echo "==> ${VM_PATH} already exists in the VM; leaving it alone"
    echo "    (delete it there first if you want a clean re-seed)"
  else
    # A bundle rather than scp/tar of the working tree: it carries the full history in one
    # file, and it sidesteps macOS tar writing AppleDouble `._*` companions for every file
    # with an extended attribute — which is what the first attempt at this produced.
    local bundle
    bundle="$(mktemp -t bento-bundle)"
    trap 'rm -f "${bundle}"' RETURN

    echo "==> Bundling history"
    git bundle create "${bundle}" --all

    echo "==> Cloning it into ${VM_PATH}"
    # shellcheck disable=SC2046
    scp $(ssh_opts) -q "${bundle}" "${VM_USER}@localhost:/tmp/bento.bundle"
    vm_ssh "
      set -e
      git clone -q --branch main /tmp/bento.bundle ${VM_PATH}
      cd ${VM_PATH}
      git remote remove origin
      git config receive.denyCurrentBranch updateInstead
      rm -f /tmp/bento.bundle
    "
  fi

  echo "==> Pointing the '${REMOTE_NAME}' remote at $(remote_url)"
  git remote remove "${REMOTE_NAME}" 2>/dev/null || true
  git remote add "${REMOTE_NAME}" "$(remote_url)"

  echo
  echo "Done. Inside the VM:"
  echo "    ssh -p ${SSH_PORT} ${VM_USER}@localhost"
  echo "    cd ~/bento && bento rebuild"
}

cmd_push() {
  require_vm
  setup_git_ssh
  cd "${REPO_ROOT}"

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"

  echo "==> Pushing ${branch} to the VM"
  # updateInstead refuses rather than clobbers if the guest tree is dirty; say so plainly.
  if ! git push "${REMOTE_NAME}" "${branch}"; then
    echo >&2
    echo "hint: if this was rejected for a dirty working tree, the VM has uncommitted" >&2
    echo "      changes. Commit them there and './scripts/vm-sync.sh pull' first." >&2
    exit 1
  fi
}

cmd_pull() {
  require_vm
  setup_git_ssh
  cd "${REPO_ROOT}"

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"

  echo "==> Fetching ${branch} from the VM"
  git fetch "${REMOTE_NAME}" "${branch}"

  # Fast-forward only. A divergence here means the same config was edited on both sides,
  # and quietly inventing a merge commit for an OS definition is not a favour.
  if git merge-base --is-ancestor HEAD FETCH_HEAD; then
    git merge --ff-only FETCH_HEAD
    echo "==> Host is now at $(git rev-parse --short HEAD)"
  elif git merge-base --is-ancestor FETCH_HEAD HEAD; then
    echo "==> Nothing to pull; the VM is already contained in this history"
  else
    echo "error: the host and the VM have diverged — refusing to merge automatically." >&2
    echo "       inspect it with:  git log --oneline --graph HEAD ${REMOTE_NAME}/${branch}" >&2
    exit 1
  fi
}

cmd_status() {
  require_vm
  setup_git_ssh
  cd "${REPO_ROOT}"

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  git fetch --quiet "${REMOTE_NAME}" "${branch}"

  echo "host  ${branch}  $(git rev-parse --short HEAD)  $(git log -1 --format=%s HEAD)"
  echo "vm    ${branch}  $(git rev-parse --short FETCH_HEAD)  $(git log -1 --format=%s FETCH_HEAD)"
  echo
  echo "commits on the host but not in the VM: $(git rev-list --count FETCH_HEAD..HEAD)"
  echo "commits in the VM but not on the host: $(git rev-list --count HEAD..FETCH_HEAD)"
  echo
  echo "VM working tree:"
  vm_ssh "git -C ${VM_PATH} status --short --branch" | sed 's/^/  /'
}

subcommand="${1:-}"
[ $# -gt 0 ] && shift || true

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-port) SSH_PORT="${2:?--ssh-port needs an argument}"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "${subcommand}" in
  init) cmd_init ;;
  push) cmd_push ;;
  pull) cmd_pull ;;
  status) cmd_status ;;
  ""|-h|--help|help) usage ;;
  *) echo "error: unknown subcommand: ${subcommand}" >&2; echo >&2; usage >&2; exit 2 ;;
esac
