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

      # `*` = every output, and it has to be `*` and **not** the empty field that every
      # hyprpaper example writes as `wallpaper = ,/path`. Both are documented as wildcards
      # and only one of them works in 0.8.4. From its own source, in
      # `src/config/WallpaperMatcher.cpp`:
      #
      #   // "*" is preferred since hyprlang's special category system doesn't properly
      #   // return entries with empty string keys from listKeysForSpecialCategory().
      #
      # The empty key never comes back out of the config, so no setting is registered and
      # hyprpaper logs `Monitor Virtual-1 has no target: no wp will be created` — at DEBUG
      # level, on a service that is otherwise `active (running)`. The desktop just has no
      # wallpaper and nothing anywhere says it failed.
      #
      # The output is still not named: the guest has exactly one, called whatever
      # virtio-gpu's EDID says, and hardcoding that would tie the config to the emulated
      # hardware (home/chime/hyprland.nix takes the same line with `monitor`).
      wallpaper = [ "*,${theme.wallpaper}" ];
    };
  };
}
