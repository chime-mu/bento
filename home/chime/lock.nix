# hyprlock + hypridle — the lock screen and the thing that decides when to show it.
#
# One file, because they are one behaviour: hypridle is a timer whose only job here is to
# run hyprlock, and splitting them would mean reading two files to answer "when does this
# machine lock?".
#
# **hyprlock needs a PAM stack**, and it is a NixOS-level fact, not a home-manager one —
# `security.pam.services.hyprlock` lives in modules/desktop.nix. Without it hyprlock falls
# back to shelling out to `su`, which on this machine means a lock screen that will not
# accept the correct password. Nothing warns you; you find out while locked out.
{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  softwareRendering = osConfig.bento.desktop.softwareRendering;

  theme = import ./theme;
  inherit (theme) colors font;

  hyprlock = lib.getExe pkgs.hyprlock;
in
{
  programs.hyprlock = {
    enable = true;

    settings = {
      general = {
        hide_cursor = true;
        # Refuse an empty submit rather than counting it as a failed attempt.
        ignore_empty_input = true;
        # `grace` used to live here and is gone in 0.9.6 — `config option <general:grace>
        # does not exist`, printed once to stderr and then "Proceeding ignoring faulty
        # entries", which is easy to miss inside hypridle's journal. The full set is
        # text_trim, hide_cursor, ignore_empty_input, immediate_render, fractional_scaling,
        # screencopy_mode and fail_timeout; anything else a guide names is stale.
      };

      # Same reasoning as home/chime/hyprland.nix: no GPU, so no animation. hyprlock
      # defaults this on and it is a separate setting from the compositor's.
      animations.enabled = !softwareRendering;

      background = [
        {
          path = "${theme.wallpaper}";
          # Blur is a full-screen shader pass per level, and this machine has no GPU to
          # run it on (learned/phase-0.md §2). The wallpaper is dim enough already.
          blur_passes = 0;
        }
      ];

      # The clock, above the field.
      label = [
        {
          text = "$TIME";
          color = colors.rgba colors.hex.foreground "ff";
          font_family = font.mono;
          font_size = 64;
          position = "0, 140";
          halign = "center";
          valign = "center";
          shadow_passes = 0;
        }
        {
          # hyprlock's own strftime, so this needs no external command on a timer.
          text = ''cmd[update:60000] date +"%A, %d %B"'';
          color = colors.rgba colors.hex.muted "ff";
          font_family = font.mono;
          font_size = 18;
          position = "0, 70";
          halign = "center";
          valign = "center";
          shadow_passes = 0;
        }
      ];

      # Hyphen in the name, so it has to be quoted in Nix; hyprlang spells the block
      # `input-field`.
      "input-field" = [
        {
          size = "300, 48";
          position = "0, -40";
          halign = "center";
          valign = "center";

          outline_thickness = 1;
          rounding = 10;

          # hyprlock fades the field out two seconds after the input goes empty
          # (`fade_on_empty` defaults to 1). It looks good on a laptop and it is actively
          # misleading here: a screenshot of this machine taken more than two seconds after
          # it locked shows a wallpaper and a clock and *no password box*, which reads as
          # "the input field failed to render" — that was the first conclusion drawn from
          # exactly that screenshot. On a machine whose screen is inspected by an agent,
          # the field stays put.
          fade_on_empty = false;
          dots_size = 0.26;
          dots_spacing = 0.3;
          dots_center = true;

          # `input-field` has its own `font_family`, defaulting to "Sans" — the labels'
          # setting does not reach it, and the placeholder renders in DejaVu while the
          # clock above it is CaskaydiaMono.
          font_family = font.mono;

          outer_color = colors.rgba colors.hex.border "ff";
          inner_color = colors.rgba colors.hex.surface "ff";
          font_color = colors.rgba colors.hex.foreground "ff";
          check_color = colors.rgba colors.hex.accent "ff";
          fail_color = colors.rgba colors.hex.error "ff";

          # No pango markup in these: hyprlang treats `#` as a comment character, so a
          # `<span foreground="#7aa2f7">` has to be written `##7aa2f7` and is a standing
          # invitation to get it wrong. Plain text needs no escaping.
          placeholder_text = "Locked";
          fail_text = "$FAIL ($ATTEMPTS)";

          shadow_passes = 0;
        }
      ];
    };
  };

  services.hypridle = {
    enable = true;

    settings = {
      general = {
        # `pidof` first, or every timeout after the first stacks another hyprlock on top
        # of the one already showing. Absolute paths because a systemd user unit does not
        # inherit a login shell's PATH.
        lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${hyprlock}";
        before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";
      };

      # One listener, and a long one. PLAN-v1 §4 asks for "idle timers long in a VM"; the
      # reason is sharper than slowness — this desktop is watched through QEMU's scanout
      # by `scripts/vm-screenshot.sh`, and a lock screen that appears while an agent is
      # halfway through a check reads as a broken desktop.
      #
      # There is deliberately **no DPMS listener**. On real hardware blanking the panel
      # after the lock is the right thing; here "the monitor" is a virtual scanout, and
      # switching it off makes the only window onto this machine go black — indisting-
      # uishable, in a screenshot, from a guest that has hung.
      listener = [
        {
          timeout = 1800;
          on-timeout = "${pkgs.systemd}/bin/loginctl lock-session";
        }
      ];
    };
  };
}
