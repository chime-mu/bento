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
      # Nothing changes the wallpaper at runtime in v1, so hyprpaper does not need to sit
      # on a control socket. A theme switcher (out of scope, see home/chime/theme) would
      # turn this back on and talk to it with `hyprctl hyprpaper wallpaper`.
      ipc = "off";
      splash = false;

      preload = [ "${theme.wallpaper}" ];

      # Empty monitor field = every output. The guest has exactly one, named by whatever
      # virtio-gpu's EDID says, so naming it here would be a hostage to the emulated
      # hardware (home/chime/hyprland.nix takes the same line with `monitor`).
      wallpaper = [ ",${theme.wallpaper}" ];
    };
  };
}
