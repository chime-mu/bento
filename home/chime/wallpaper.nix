# The wallpaper — drawn by **swaybg**, not by hyprpaper.
#
# PLAN-v1 §4 names hyprpaper. It is in nixpkgs, it is cached for aarch64, it starts, it
# parses this config — and it segfaults on this guest, every time, within a second:
#
#   ERR from aquamarine ]: GBM: Failed to allocate a GBM buffer: bo null
#   ERR from aquamarine ]: Couldn't allocate a gbm buffer with size [1920, 1080]
#                          and format AB4H
#   ERR from aquamarine ]: Swapchain: Failed acquiring a buffer
#   hyprpaper.service: Main process exited, code=dumped, status=11/SEGV
#
# `AB4H` is DRM_FORMAT_ABGR16161616F — half-float colour. hyprpaper 0.8 draws through
# hyprtoolkit, which asks aquamarine's GBM allocator for that format; virtio-gpu does not
# offer it, `gbm_bo_create` returns null, and `CWaylandBuffer`'s constructor dereferences
# the null on the very first `zwlr_layer_surface_v1.configure`. It is a null check
# upstream is missing, not something this configuration can set its way out of:
# `AQ_NO_MODIFIERS=1` and `AQ_FORCE_LINEAR_BLIT=1` — the aquamarine knobs
# learned/phase-3.md §2 points at — make no difference, tested A/B.
#
# swaybg wants none of that. It is wl_shm and cairo: it hands the compositor a shared
# memory buffer and lets *the compositor* be the one with a renderer. On a machine whose
# defining property is that it has no GPU (learned/phase-0.md §2), that is the right
# architecture, and the substitution is arguably an improvement rather than a compromise.
#
# The wallpaper file itself is where learned/phase-2.md §3 bites: a new PNG is untracked,
# a flake cannot see untracked files, and the failure is silent. `bento rebuild` runs
# `git add -N` first for exactly this. If the desktop comes up empty, check `git status`
# before checking the daemon.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  theme = import ./theme;
in
{
  home.packages = [ pkgs.swaybg ];

  # No home-manager module for swaybg, so the unit is written here. Same shape as the mako
  # one: bound to the graphical session, which home-manager's Hyprland module only reaches
  # after it has pushed WAYLAND_DISPLAY into the systemd environment.
  systemd.user.services.swaybg = {
    Unit = {
      Description = "swaybg wallpaper";
      Documentation = [ "man:swaybg(1)" ];
      PartOf = [ config.wayland.systemd.target ];
      After = [ config.wayland.systemd.target ];
      ConditionEnvironment = [ "WAYLAND_DISPLAY" ];
    };

    Service = {
      Type = "simple";
      # No `--output`: with none given swaybg covers every output, which avoids naming the
      # one this guest has. It is called whatever virtio-gpu's EDID says, and hardcoding
      # that would tie the configuration to the emulated hardware — the same reason
      # home/chime/hyprland.nix leaves `monitor` blank.
      #
      # `fill` scales and crops to cover. The image is generated at exactly 1920×1080
      # (scripts/make-wallpaper.py), which is what scripts/run-vm.sh asks virtio-gpu for,
      # so today it is a no-op — and it stays correct if either number changes.
      ExecStart = "${lib.getExe pkgs.swaybg} --mode fill --image ${theme.wallpaper}";
      Restart = "on-failure";
    };

    Install.WantedBy = [ config.wayland.systemd.target ];
  };
}
