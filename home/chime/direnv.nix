# direnv — the per-directory half of this machine's toolchain.
#
# modules/pins.nix and the system package lists answer "what does this machine have";
# this answers "what does this *project* have". A repository carrying a flake.nix and a
# one-line .envrc gets its own toolchain on `cd`, and gives it back on the way out:
#
#     $ cat .envrc
#     use flake
#
# That is the asdf/mise workflow — a global default, overridden per directory by a file
# checked into the project — without the part that makes it awkward here. asdf and mise
# keep their state in ~/.local/share and install prebuilt generic-Linux binaries, which
# on NixOS meet a stub loader that refuses to run them:
#
#     $ /lib/ld-linux-aarch64.so.1
#     Could not start dynamically linked executable: /lib/ld-linux-aarch64.so.1
#     NixOS cannot run dynamically linked executables intended for generic
#     linux environments out of the box.
#
# The usual fix is `programs.nix-ld.enable`, which works by making the machine less
# reproducible. direnv needs no such thing: the project's toolchain is a devShell, built
# by the same Nix as everything else, and the pin lives in the project's own flake.lock.
#
# nix-direnv is what makes it bearable in practice. Plain `use flake` re-evaluates the
# shell on every `cd` and leaves nothing to garbage-collect against, so devShells get
# swept and rebuilt; nix-direnv caches the evaluation and roots it against the GC.
{ ... }:
{
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # direnv is a shell hook before it is anything else, and home-manager only writes that
  # hook into a shell it manages: `programs.direnv.enableBashIntegration` appends to
  # `programs.bash.initExtra`, which is written only when `programs.bash.enable` is set.
  # Without this line direnv installs, appears on PATH, and silently never activates —
  # `direnv status` reports "found RC" but no environment is ever loaded.
  #
  # chime's login shell is already bash (`users.users.chime` sets no `shell`, so it takes
  # the NixOS default), and there were no dotfiles in ~ for home-manager to collide with.
  programs.bash.enable = true;
}
