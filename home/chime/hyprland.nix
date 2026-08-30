# Hyprland's user configuration: what the keyboard does, and how the compositor behaves on
# a machine with no GPU.
#
# The compositor itself is installed by the NixOS module (modules/desktop.nix), so both
# `package` and `portalPackage` are null here — home-manager then writes the config file
# and the systemd session target and installs nothing. Setting them would put a second,
# separately-built Hyprland in the user profile and let `Hyprland` mean different binaries
# depending on PATH order.
{
  lib,
  osConfig,
  ...
}:
let
  # home-manager sees the NixOS configuration as `osConfig`, which is how a *user* setting
  # can key off a *machine* fact. Both uses below are the same question — "is there a GPU?"
  # — and answering it from the host rather than hardcoding it is what keeps this file
  # correct when bento eventually boots on real hardware.
  softwareRendering = osConfig.bento.desktop.softwareRendering;

  # Super+1..9 and Super+0 for workspace 10, plus the Shift variants that move the focused
  # window there. Written out rather than hand-listed because twenty near-identical lines
  # are twenty chances to typo one of them.
  workspaceBinds = lib.concatMap (
    i:
    let
      ws = toString (i + 1);
      key = toString (if i == 9 then 0 else i + 1);
    in
    [
      "$mod, ${key}, workspace, ${ws}"
      "$mod SHIFT, ${key}, movetoworkspace, ${ws}"
    ]
  ) (lib.range 0 9);
in
{
  wayland.windowManager.hyprland = {
    enable = true;
    package = null;
    portalPackage = null;

    # Explicit, because home-manager's default flipped to "lua" for `home.stateVersion`
    # 26.05 and later — and ours is 26.11, so leaving this out writes hyprland.lua instead
    # of hyprland.conf. hyprlang is what wiki.hypr.land and every Omarchy reference are
    # written in, and Phases 4 and 5 lean on those; a config language is a bad thing to
    # have to translate mid-plan. Being explicit also pins it against a future default flip.
    configType = "hyprlang";

    settings = {
      "$mod" = "SUPER";
      # Phase 5 replaces this with ghostty and keeps foot as the fallback. One variable, so
      # that is a one-line change and every bind follows it.
      "$terminal" = "foot";

      # No hardcoded mode: virtio-gpu ships an EDID (edid=on by default) carrying the
      # xres/yres that scripts/run-vm.sh asks for, so `preferred` tracks the QEMU window
      # instead of fighting it. Scale 1 — the Cocoa display is not HiDPI-aware here without
      # try-omarchy's QEMU patch (learned/phase-0.md §3).
      monitor = ",preferred,auto,1";

      general = {
        gaps_in = 4;
        gaps_out = 8;
        border_size = 2;
        layout = "dwindle";
      };

      # Everything expensive is off while we are on llvmpipe: blur and shadows are
      # full-screen fragment work, and each one is paid for by the CPU on every frame.
      # Phase 4 themes what is left; Phase 6, if it ever lands GL, can turn these back on.
      decoration = {
        rounding = 6;
        blur.enabled = !softwareRendering;
        shadow.enabled = !softwareRendering;
      };

      animations.enabled = !softwareRendering;

      misc = {
        # `misc:vfr` — which every VM guide still tells you to set — no longer exists in
        # 0.56; variable refresh moved to `debug:vfr` and defaults to on, so the frame we
        # care about not drawing is already not drawn. Setting the old name is not ignored,
        # it is an error printed across the top of the screen at every launch.
        #
        # Deliberately *not* disabling the Hyprland logo yet. Until Phase 4 lands a
        # wallpaper it is the only thing on an empty screen that distinguishes "Hyprland is
        # running" from "the VM hung during boot" — which is exactly the question Phase 3's
        # acceptance asks a human to answer by looking at the QEMU window.
        disable_hyprland_logo = false;
      };

      cursor = {
        # There is no hardware cursor plane to put a cursor on. Left to its own devices
        # Hyprland probes for one, and the failure shows up as an invisible or stuttering
        # pointer rather than as an error.
        no_hardware_cursors = softwareRendering;
      };

      input = {
        kb_layout = "us";
        follow_mouse = 1;
        # QEMU's usb-tablet sends absolute coordinates, so pointer acceleration would be
        # applied to a position that is already exactly where the host's cursor is.
        accel_profile = "flat";
      };

      # Omarchy's scheme, as far as Phase 3 has software to bind to. Super+Space (the
      # launcher) arrives with walker in Phase 4, and Super+B (the browser) with chromium
      # in Phase 5 — they are absent rather than bound to a placeholder, so that a key that
      # does nothing means "not built yet" instead of "broken".
      bind = [
        "$mod, RETURN, exec, $terminal"
        "$mod, W, killactive,"
        "$mod, F, fullscreen, 0"
        "$mod, V, togglefloating,"
        # `togglesplit` is no longer a dispatcher in 0.56 — it is a message to the dwindle
        # layout, and the old spelling fails loudly at launch. `pseudo` is still its own
        # dispatcher, which is why only one of these two lines had to change.
        "$mod, J, layoutmsg, togglesplit"
        "$mod, P, pseudo,"

        "$mod, left, movefocus, l"
        "$mod, right, movefocus, r"
        "$mod, up, movefocus, u"
        "$mod, down, movefocus, d"

        "$mod SHIFT, left, swapwindow, l"
        "$mod SHIFT, right, swapwindow, r"
        "$mod SHIFT, up, swapwindow, u"
        "$mod SHIFT, down, swapwindow, d"

        # Writes the whole output to a timestamped PNG. The same tool an agent uses over
        # ssh to see this desktop, bound where a human can reach it.
        ''$mod SHIFT, S, exec, grim "$HOME/Pictures/bento-$(date +%Y%m%d-%H%M%S).png"''

        # Ends the session. greetd does not restart into the autologin, so this drops to
        # agreety's login prompt rather than looping back into a new Hyprland.
        "$mod SHIFT, Q, exit,"
      ]
      ++ workspaceBinds;

      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];
    };
  };

  # The screenshot bind writes here, and grim will not create the directory itself.
  home.file."Pictures/.keep".text = "";
}
