# home-manager entry point for chime.
#
# One file per program, and `./theme` is not among them — it is a plain expression that
# each of the others imports for its colours, font and wallpaper, not a module with
# options of its own. Phase 5 adds ghostty.nix and neovim.nix here.
{ ... }:
{
  imports = [
    ./hyprland.nix
    ./waybar.nix
    ./walker.nix
    ./mako.nix
    ./hyprpaper.nix
    ./lock.nix
  ];

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
