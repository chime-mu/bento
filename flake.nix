{
  description = "bento — a NixOS desktop OS, Omarchy-inspired, agent-supported";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, home-manager, ... }@inputs:
    let
      system = "aarch64-linux";
    in
    {
      nixosConfigurations.bento-vm = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/bento-vm

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; };
            home-manager.users.chime = import ./home/chime;
          }

          # Point the VM's own `nixpkgs` at the revision this image was built from, so an
          # agent working inside the VM resolves the same tree the flake locked.
          {
            nix.registry.nixpkgs.flake = nixpkgs;
            nix.nixPath = [ "nixpkgs=${nixpkgs}" ];
          }
        ];
      };

      packages.${system} = {
        # A qcow2 with an EFI partition table and systemd-boot.
        #
        # This is nixpkgs' own image builder, reached through `system.build.images`, and
        # NOT nixos-generators' `qcow-efi` that PLAN-v1 names — see learned/phase-1.md.
        # Because `image.modules` layers the format on top of this very configuration via
        # `extendModules`, the image and `nixos-rebuild switch` inside the VM cannot
        # describe two different machines.
        bento-image =
          let
            base = self.nixosConfigurations.bento-vm.config.system.build.images.qemu-efi;
          in
          # `make-disk-image` lays out the partitions and installs the bootloader inside
          # `vmTools.runInLinuxVM`, which unconditionally declares
          # `requiredSystemFeatures = [ "kvm" ]`. Our builder is itself a QEMU guest under
          # hvf, and hvf exposes no nested virtualisation, so it has no /dev/kvm and Nix
          # refuses to schedule the build at all.
          #
          # The gate is about speed, not capability: `nixos/lib/qemu-common.nix` builds the
          # inner QEMU command with `accel=kvm:tcg`, which falls back to emulation. Dropping
          # the requirement lets the image build here — slowly, once. See learned/phase-1.md.
          #
          # `overrideDerivation`, not `overrideAttrs`: `runInLinuxVM` returns a bare
          # `derivation`, not a `mkDerivation`, so it carries no `overrideAttrs`.
          nixpkgs.lib.overrideDerivation base (_: { requiredSystemFeatures = [ ]; });

        default = self.packages.${system}.bento-image;
      };

      # The aarch64-linux builder, with resources that match the host.
      #
      # Stock `darwin.linux-builder` gives the guest 1 core and 3 GiB. That is painful
      # anywhere, and actively prohibitive here: the image build runs an emulated inner
      # QEMU (see `bento-image` above), and emulation is exactly the workload that wants
      # cores and memory. The host has 10 cores and 32 GiB.
      #
      # `virtualisation.diskSize` is deliberately left alone — changing it would orphan
      # the existing ~/.local/state/bento/builder-disk.qcow2 and force the builder to
      # refetch its whole store.
      packages.aarch64-darwin.linux-builder =
        nixpkgs.legacyPackages.aarch64-darwin.darwin.linux-builder.override {
          modules = [
            # mkForce, because nixos/modules/profiles/nix-builder.nix pins both of these
            # with plain definitions rather than defaults.
            (
              { lib, ... }:
              {
                virtualisation.cores = lib.mkForce 8;
                virtualisation.memorySize = lib.mkForce 12288;
              }
            )
          ];
        };
    };
}
