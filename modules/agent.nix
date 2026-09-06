# The agent's toolchain — Claude Code and the things it reaches for.
#
# This is the module PLAN-v1 calls "the point of the OS". bento's premise is that changing
# the machine means asking an agent to edit the flake and apply it, so the agent is not an
# application that happens to be installed: it is part of the system, in the same list as
# sshd and the compositor, and it is installed for *every* user rather than for `chime`'s
# home-manager profile alone. A machine where root can rebuild the OS but the agent cannot
# see the tools it needs is a machine that has missed the point.
#
# Host-agnostic, like core.nix and desktop.nix — nothing here is true only of the VM.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # The agent itself. Unfree, and `nixpkgs.config.allowUnfree = true` in modules/core.nix
    # is what lets it evaluate — set there since Phase 1, for this.
    #
    # A note for anyone probing it by hand: `nix build nixpkgs#claude-code` fails on its
    # own with an assertion out of lib/customisation.nix. That is only the unfree licence
    # gate — the bare `nixpkgs#` registry reference does not inherit this flake's
    # `allowUnfree`. Inside `nixosConfigurations.bento-vm` it is fine. To dry-run it:
    #   NIXPKGS_ALLOW_UNFREE=1 nix build --dry-run --impure nixpkgs#claude-code
    claude-code

    # **`nodejs-slim`, not `nodejs`** — the one substitution PLAN-v1 risk #2 actually
    # forces in this phase. Measured on this guest:
    #
    #   nixpkgs#nodejs        24.19.0  → "this derivation will be built"   ← a V8 compile
    #   nixpkgs#nodejs-slim   24.19.0  → 28 paths fetched, 0 built
    #
    # Same Node, same version; `nodejs` differs only in that it carries npm, and it is the
    # npm wrapper that puts it off the cached path. Compiling V8 inside an emulated
    # aarch64 VM is exactly the trade risk #2 says not to make.
    #
    # (`nodejs_20`, which learned/HANDOFF.md suggested as the alternative, no longer
    # exists: nixpkgs now throws "Node.js 20 support was removed given upstream
    # End-of-Life on 2026-04-30". `nodejs_22` and `nodejs_24` both build from source too.)
    #
    # claude-code brings its own Node for its own bundle, so this is here for what the
    # agent *runs*, not for what it is.
    nodejs-slim

    # The tools Claude Code leans on when it searches and edits a repository. ripgrep and
    # fd in particular are not conveniences — the agent's file search assumes them and
    # falls back to something much slower without.
    ripgrep
    fd
    gh
    curl

    # Also in modules/desktop.nix, where home-manager's Hyprland reload hook calls it by
    # bare name. Listed again here because this module has to stand up on a headless bento
    # that never imports the desktop, and NixOS deduplicates identical store paths.
    jq

    # **The interpreter scripts/check-before-commit.sh names as a `require_command`.**
    # Without it the repository's own mandated pre-commit check aborts on its first line,
    # on the very machine the repository builds — which is the failure this module's
    # opening paragraph describes: the agent can rebuild the OS but cannot see the tools
    # it needs.
    #
    # It is also what scripts/run-vm.sh and scripts/vm-screenshot.sh fall back to off the
    # host, so the QEMU-stub tests in tests/ run here as well as on macOS.
    #
    # Cached, unlike `nodejs` above — `nix build --dry-run` fetches it and every other
    # mainstream language runtime rather than building, so PLAN-v1 risk #2 is not in play.
    python3
  ];

  # `bento doctor` — see modules/bento-cli.nix.
  #
  # PLAN-v1 §5 step 4 puts the doctor script in this file. It lives in bento-cli.nix
  # instead, because `doctor` is a *verb of the `bento` command* and that file owns the
  # subcommand dispatch (learned/phase-2.md §6 named it as the seam to hang this off).
  # Shipping a second binary here just to avoid touching that dispatch would give the
  # machine two CLIs that both answer questions about it.
}
