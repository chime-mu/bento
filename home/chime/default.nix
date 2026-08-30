# home-manager entry point for chime.
#
# Phase 3 added hyprland.nix. The rest of the desktop — waybar, walker, mako, the Tokyo
# Night theme — lands in Phase 4, one file each, imported here.
{ ... }:
{
  imports = [ ./hyprland.nix ];

  home.stateVersion = "26.11";
  programs.home-manager.enable = true;

  programs.git = {
    enable = true;
    # `userName`/`userEmail` were renamed to `settings.user.*` in home-manager; the old
    # names still evaluate but warn on every build.
    settings.user = {
      name = "Michael Arnoldus";
      email = "chime@mu.dk";
    };
  };
}
