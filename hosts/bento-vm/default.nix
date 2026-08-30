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
    ../../modules/desktop.nix
    ../../modules/fonts.nix
  ];

  # Which `nixosConfigurations.<name>` `bento rebuild` applies. Stated here rather than
  # left to the module default, because this is the one fact only the host knows.
  bento.cli.configuration = "bento-vm";

  # There is no GPU behind this machine's virtio-gpu: the host's Homebrew QEMU has no
  # OpenGL compiled in, so there is no VirGL to accelerate through and llvmpipe is the only
  # renderer available (learned/phase-0.md §2 — measured, not assumed). Stated here because
  # it is a fact about *this host*, and the desktop module is meant to be reusable by a
  # bare-metal one that will not set it.
  bento.desktop.softwareRendering = true;

  # The release this machine was first installed from. Never bump it to follow nixpkgs —
  # it exists precisely to keep stateful defaults (databases, service layouts) stable
  # across upgrades.
  system.stateVersion = "26.11";
}
