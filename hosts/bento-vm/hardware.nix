# What the guest needs to know about its virtual hardware.
#
# The disk layout here is *also* set by nixpkgs' `qemu-efi` image module, but that module
# only exists while building the image. `nixos-rebuild switch` inside the VM (Phase 2)
# evaluates `nixosConfigurations.bento-vm` on its own, and without these it fails with
# "the ‘fileSystems’ option does not specify your root file system".
#
# So the overlapping options are `lib.mkDefault`: the image module's plain definitions win
# during the image build, these apply everywhere else, and the two agree anyway.
{ lib, modulesPath, ... }:
{
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/nixos";
    fsType = lib.mkDefault "ext4";
    autoResize = lib.mkDefault true;
  };

  fileSystems."/boot" = {
    device = lib.mkDefault "/dev/disk/by-label/ESP";
    fsType = lib.mkDefault "vfat";
  };

  # build-image.sh hands run-vm.sh a qcow2 far larger than the image was built at; these
  # two grow the partition and then the root filesystem into it on first boot.
  boot.growPartition = true;

  # systemd-boot, and it must install without writing EFI variables: Homebrew ships no
  # edk2-aarch64-vars.fd, so run-vm.sh fabricates the initial 64 MiB store and replaces it
  # when the host's emulated hardware profile changes (learned/phase-0.md §2).
  # `bootctl install` therefore has to leave a loader at the removable-media fallback
  # path, /EFI/BOOT/BOOTAA64.EFI, which is what it does without recording a boot entry.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  # Long enough to pick an older generation from the serial console — the whole premise
  # of this OS is an agent rewriting it, so the escape hatch has to be reachable.
  boot.loader.timeout = 3;

  # The `virt` machine's serial port is ttyAMA0, not ttyS0 — this is the console that
  # run-vm.sh's `-serial mon:stdio` lands on. tty0 keeps the QEMU graphical window usable
  # as well.
  boot.kernelParams = [
    "console=tty0"
    "console=ttyAMA0,115200"
  ];

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "virtio_net"
    "xhci_pci"
    "usbhid"
    "sr_mod"
  ];

  # Size of the image as built. The runtime disk is whatever build-image.sh resized the
  # writable copy to, so this only has to fit the closure.
  virtualisation.diskSize = lib.mkDefault (8 * 1024);

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
