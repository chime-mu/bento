# Facts true of every bento machine: who logs in, how Nix behaves, what a bare shell has.
# Host-agnostic on purpose — virtual-hardware specifics live in hosts/bento-vm/hardware.nix
# so a future bare-metal host can import this file unchanged.
{ pkgs, ... }:
{
  networking.hostName = "bento";

  time.timeZone = "Europe/Copenhagen";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME = "en_DK.UTF-8";
    LC_MEASUREMENT = "da_DK.UTF-8";
    LC_MONETARY = "da_DK.UTF-8";
    LC_PAPER = "da_DK.UTF-8";
  };
  # extraLocaleSettings does not imply generation — anything named above must be listed
  # here too or the setting silently falls back to C at runtime.
  i18n.supportedLocales = [
    "C.UTF-8/UTF-8"
    "en_US.UTF-8/UTF-8"
    "en_DK.UTF-8/UTF-8"
    "da_DK.UTF-8/UTF-8"
  ];

  users.users.chime = {
    isNormalUser = true;
    description = "chime";
    extraGroups = [ "wheel" ];
    # Only ever applied when the account is first created, so changing it later needs
    # `passwd`. It exists so the serial console is usable before SSH is reachable.
    initialPassword = "bento";
    openssh.authorizedKeys.keys = [
      # ~/.ssh/id_ed25519.pub on the Mac host. A plain key, not one of the YubiKey-backed
      # sk-* ones, deliberately: an agent driving this VM cannot touch a hardware key.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLhxvO9zOG7Ab+8h2iiz4aJrns7YtZMrUHHt5kndGu8 ma@goodmonday.io"
    ];
  };

  # A disposable dev VM whose whole premise is an agent running `nixos-rebuild switch`.
  security.sudo.wheelNeedsPassword = false;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Lets chime rebuild the OS without every command going through root.
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  # claude-code is unfree; it arrives in Phase 5 but the flag belongs with the rest of
  # the Nix configuration.
  nixpkgs.config.allowUnfree = true;

  services.openssh = {
    enable = true;
    # The key above is the intended route in; passwords stay on as the fallback for a
    # VM reachable only through the host's loopback forward.
    settings.PasswordAuthentication = true;
    settings.PermitRootLogin = "no";
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    htop
  ];
}
