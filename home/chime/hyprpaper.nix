# hyprpaper — puts the wallpaper on the root surface.
#
# The wallpaper itself is `home/chime/theme/tokyo-night.png`, referenced through the theme
# as a Nix *path*, so it is copied into the store and this config names an immutable path
# rather than something under $HOME that could be missing at login.
#
# It is also the file that makes learned/phase-2.md §3 concrete: a new PNG is untracked,
# a flake cannot see untracked files, and the failure is silent — the wallpaper is simply
# absent with no error anywhere. `bento rebuild` runs `git add -N` first for this reason.
# If the desktop comes up empty, check `git status` before checking hyprpaper.
{ ... }:
let
  theme = import ./theme;
in
{
  services.hyprpaper = {
    enable = true;

    settings = {
      splash = false;

      # **hyprpaper 0.8 has a different configuration language from every example you will
      # find**, and it does not say so. `preload = <path>` and `wallpaper = <monitor>,<path>`
      # — the two lines in the wiki, in the man page's examples, and in every dotfiles repo
      # — are simply gone. `src/config/ConfigManager.cpp` registers no `preload` value and
      # no `wallpaper` handler; `wallpaper` is a hyprlang **special category** keyed on
      # `monitor`, so it is a block with fields:
      #
      #     wallpaper {
      #       monitor = *
      #       path = /nix/store/…-tokyo-night.png
      #     }
      #
      # which is what home-manager writes for a *list of attrsets* (a list of strings would
      # write the old `wallpaper = …` line). Preloading is implicit now.
      #
      # The old spelling does not fail — it is accepted, ignored, and hyprpaper runs
      # happily with nothing to draw, logging `Monitor Virtual-1 has no target: no wp will
      # be created` at DEBUG on a service that reports `active (running)`.
      #
      # `monitor = *`, not the empty string that also means "all outputs": hyprpaper's own
      # source says why, in `src/config/WallpaperMatcher.cpp` —
      #   // "*" is preferred since hyprlang's special category system doesn't properly
      #   // return entries with empty string keys from listKeysForSpecialCategory().
      # The output is not named for the reason home/chime/hyprland.nix does not name it
      # either: it is whatever virtio-gpu's EDID says, and hardcoding that ties the
      # configuration to the emulated hardware.
      wallpaper = [
        {
          monitor = "*";
          path = "${theme.wallpaper}";
          fit_mode = "cover";
        }
      ];
    };
  };
}
