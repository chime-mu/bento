# home-manager entry point for chime.
#
# Near-empty by design in Phase 1. The desktop — hyprland, waybar, walker, mako, the
# Tokyo Night theme — lands in Phases 3 and 4. It exists this early so the home-manager
# wiring is already proven before there is anything complicated inside it to blame.
{ ... }:
{
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
