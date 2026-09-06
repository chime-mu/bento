# Version pins for packages nixpkgs carries but does not track closely enough.
#
# nixpkgs is the package manager here, and for almost everything its cadence is right:
# a language runtime that moves every few months is well served by `bento update
# nixpkgs`. A handful of tools move faster than any distribution can follow. Claude Code
# ships several releases a day and expects to update itself, which a read-only store
# makes impossible — so the choice is between running whatever nixpkgs last vendored and
# pinning the version ourselves.
#
# Measured on 2026-09-06: nixpkgs carried 2.1.245 (built 2026-08-25) while upstream was
# at 2.1.263, twelve days and eighteen patches ahead. Worth noting before this looks
# worse than it is — Anthropic's own `stable` dist-tag was 2.1.236 at the same moment,
# *behind* nixpkgs. The lag is real; it is not the emergency the release rate suggests.
#
# What makes this cheap is that nixpkgs' derivation was built to be pinned. From
# pkgs/by-name/cl/claude-code/package.nix:
#
#   manifest ? lib.importJSON ./manifest.json,
#
# The manifest carries the version and a SHA-256 for every platform; the derivation
# fetches `downloads.claude.ai/claude-code-releases/$version/$platform/claude` and runs
# autoPatchelfHook over it. So overriding one argument re-points the whole build at a
# different release, with upstream's own checksums, through a seam nixpkgs maintains.
# This is not a fork and not a vendored expression — if that argument ever disappears,
# evaluation fails loudly rather than silently reverting to nixpkgs' version.
#
# Every property that makes Nix worth using survives:
#
#   * the version is `pkgs/claude-code/manifest.json`, checked into git — the machine's
#     claude-code is as reproducible as everything else in this flake
#   * the integrity check is upstream's SHA-256, not our trust in the download
#   * autoPatchelfHook fixes the binary's interpreter, so no `programs.nix-ld`, no hole
#     punched through the thing that makes NixOS reproducible
#   * nixpkgs already wraps the binary with DISABLE_AUTOUPDATER=1, so the self-updater
#     never fights the store
#   * rollback still works two ways — `nixos-rebuild --rollback`, or reverting one commit
#
# `bento update claude-code` rewrites the manifest; `bento doctor` prints what is pinned.
#
# The generalisation is deliberately not written yet. The convention this establishes is
# `pkgs/<name>/manifest.json`, and both `bento update` and `bento doctor` already walk
# `pkgs/*/manifest.json` rather than special-casing this one directory. What is still
# per-package is *how* a manifest is refreshed, because one example is not enough to know
# what the second one needs — Erlang and Elixir, the next candidates, are source builds
# with a single hash rather than a published multi-platform manifest, which is a
# different shape. That updater lives in modules/bento-cli.nix until there are two.
{ lib, ... }:
{
  nixpkgs.overlays = [
    (_final: prev: {
      claude-code = prev.claude-code.override {
        manifest = lib.importJSON ../pkgs/claude-code/manifest.json;
      };
    })
  ];
}
