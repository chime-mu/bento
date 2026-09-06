# bento-vm — bento running as a QEMU guest on an Apple Silicon Mac.
#
# Host-level assembly only: which modules make up this machine. Anything true of every
# bento machine belongs in ../../modules, anything true only of virtual hardware belongs
# in ./hardware.nix.
{ ... }:
{
  imports = [
    ./hardware.nix
    ./integration.nix
    ./audio.nix
    ../../modules/core.nix
    ../../modules/bento-cli.nix
    ../../modules/pins.nix
    ../../modules/languages.nix
    ../../modules/desktop.nix
    ../../modules/fonts.nix
    ../../modules/agent.nix
  ];

  # Which `nixosConfigurations.<name>` `bento rebuild` applies. Stated here rather than
  # left to the module default, because this is the one fact only the host knows.
  bento.cli.configuration = "bento-vm";

  # There *is* a GPU behind this machine's virtio-gpu, as of Phase 6. The host's Homebrew
  # QEMU still has no OpenGL in it, but `./scripts/build-qemu-gl.sh` builds one that does,
  # and `./scripts/run-vm.sh` boots with `virtio-gpu-gl-pci` whenever that binary exists.
  # The guest then reaches Metal: mesa's virgl driver → virglrenderer → ANGLE → Metal on
  # the M4, which `glxinfo -B` reports as
  #
  #   virgl (ANGLE (Apple, Apple M4, OpenGL 4.1 Metal - 90.5))   Accelerated: yes
  #
  # so blur, shadows and animations are back on (learned/phase-6.md).
  #
  # Note what this option can and cannot express. It is evaluated when the system is
  # built; whether a GPU is present is decided when the VM is launched. One disk image
  # serves both, so this is a statement about the *intended* way to run this host, not a
  # detected fact. `./scripts/run-vm.sh --no-gl` still boots and still works — the
  # compositor falls back to llvmpipe on its own, exactly as it did through Phases 3-5 —
  # it is just sluggish, because the effects below are compiled in and now cost CPU.
  # Nothing *breaks* in that mode, and that is deliberate: the one setting whose absence
  # would break it, `GSK_RENDERER=cairo`, was moved out of this option and is now
  # unconditional (learned/phase-6.md §4).
  bento.desktop.softwareRendering = false;

  # Bento's patched Cocoa frontend continuously republishes the Mac window's backing
  # geometry through virtio-gpu EDID. This is a host capability rather than a generic
  # desktop preference: it enables the guest display synchronizer and tells Hyprland
  # to leave pointer composition to Cocoa. The same cursor path also works with the
  # stock software QEMU because run-vm.sh passes show-cursor=on in graphical modes.
  bento.desktop.dynamicDisplay = true;

  # The release this machine was first installed from. Never bump it to follow nixpkgs —
  # it exists precisely to keep stateful defaults (databases, service layouts) stable
  # across upgrades.
  system.stateVersion = "26.11";
}
