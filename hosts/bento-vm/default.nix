# bento-vm — bento running as a QEMU guest on an Apple Silicon Mac.
#
# Host-level assembly only: which modules make up this machine. Anything true of every
# bento machine belongs in ../../modules, anything true only of virtual hardware belongs
# in ./hardware.nix.
{ ... }:
{
  imports = [
    ./hardware.nix
    ../../modules/core.nix
    ../../modules/bento-cli.nix
  ];

  # Which `nixosConfigurations.<name>` `bento rebuild` applies. Stated here rather than
  # left to the module default, because this is the one fact only the host knows.
  bento.cli.configuration = "bento-vm";

  # The release this machine was first installed from. Never bump it to follow nixpkgs —
  # it exists precisely to keep stateful defaults (databases, service layouts) stable
  # across upgrades.
  system.stateVersion = "26.11";
}
