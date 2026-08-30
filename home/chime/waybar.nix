# Waybar — the top bar.
#
# Started by systemd, not by a Hyprland `exec-once`: `systemd.enable` binds the unit to
# `graphical-session.target`, which home-manager's Hyprland module reaches only *after* it
# has pushed WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE into the systemd and D-Bus
# user environments. An `exec-once` races that import; a unit cannot.
#
# Module choice is shaped by the machine. There is no battery, no backlight and no audio
# device behind this QEMU guest, so the modules that would report on them are absent
# rather than present-and-empty — a bar that shows "0%" for a battery that does not exist
# is worse than one that does not mention batteries.
{ ... }:
let
  theme = import ./theme;
  inherit (theme)
    colors
    font
    icons
    ;
in
{
  programs.waybar = {
    enable = true;
    systemd.enable = true;

    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 34;
      spacing = 0;

      modules-left = [
        "hyprland/workspaces"
        "hyprland/submap"
      ];
      modules-center = [ "clock" ];
      modules-right = [
        "cpu"
        "memory"
        "network"
        "tray"
      ];

      "hyprland/workspaces" = {
        format = "{name}";
        # Only the workspaces that exist, in numeric order. Hyprland creates them lazily,
        # so without `sort-by-number` they appear in creation order and jump around.
        sort-by-number = true;
        on-click = "activate";
      };

      "hyprland/submap".format = "{}";

      clock = {
        # LC_TIME is en_DK (modules/core.nix), so ISO order everywhere else; spelled out
        # here because a bar is read at a glance and "Sat 30 Aug  14:32" beats "2026-08-30".
        format = "{:%a %d %b  %H:%M}";
        tooltip-format = "<tt>{calendar}</tt>";
        calendar = {
          mode = "month";
          format = {
            today = "<span color='${colors.css.accent}'><b>{}</b></span>";
            weekdays = "<span color='${colors.css.muted}'>{}</span>";
          };
        };
      };

      # Five seconds, not the default one: every poll is CPU spent by a bar that exists to
      # report on the CPU, and this machine renders its own pixels in software.
      cpu = {
        interval = 5;
        format = "${icons.cpu} {usage}%";
      };

      memory = {
        interval = 5;
        format = "${icons.memory} {percentage}%";
        tooltip-format = "{used:0.1f} GiB of {total:0.1f} GiB";
      };

      network = {
        interval = 10;
        format-ethernet = "${icons.network} {ifname}";
        format-disconnected = "${icons.networkOff} offline";
        tooltip-format = "{ipaddr}/{cidr} via {gwaddr}";
      };

      tray = {
        spacing = 10;
        icon-size = 16;
      };
    };

    # GTK3 CSS. Everything is flat and opaque on purpose: there is no compositor blur to
    # sit on (home/chime/hyprland.nix switches it off under software rendering), and a
    # translucent bar over a busy window would just cost llvmpipe another blend per pixel
    # for an effect nothing else on the desktop is doing.
    style = ''
      * {
        font-family: "${font.mono}", monospace;
        font-size: ${toString font.size}px;
        min-height: 0;
        border: none;
        border-radius: 0;
      }

      window#waybar {
        background: ${colors.css.background};
        color: ${colors.css.foreground};
        border-bottom: 1px solid ${colors.css.border};
      }

      /* One rule for every module, so adding a module to the JSON above is enough. */
      #workspaces,
      #submap,
      #clock,
      #cpu,
      #memory,
      #network,
      #tray {
        padding: 0 12px;
        color: ${colors.css.foregroundDim};
      }

      #workspaces {
        padding: 0 4px;
      }

      #workspaces button {
        padding: 0 9px;
        margin: 4px 2px;
        border-radius: 6px;
        color: ${colors.css.muted};
        background: transparent;
      }

      #workspaces button:hover {
        background: ${colors.css.surface};
        color: ${colors.css.foreground};
      }

      #workspaces button.active {
        background: ${colors.css.accent};
        color: ${colors.css.background};
      }

      /* Hyprland's own "urgent" hint — a window asking for attention on a workspace you
         are not looking at. */
      #workspaces button.urgent {
        background: ${colors.css.urgent};
        color: ${colors.css.background};
      }

      #submap {
        color: ${colors.css.accentAlt};
      }

      #clock {
        color: ${colors.css.foreground};
        font-weight: bold;
      }

      #cpu {
        color: ${colors.css.info};
      }

      #memory {
        color: ${colors.css.accentAlt};
      }

      #network {
        color: ${colors.css.ok};
      }

      #network.disconnected {
        color: ${colors.css.error};
      }

      #tray {
        padding-right: 14px;
      }

      #tray > .needs-attention {
        background: ${colors.css.urgent};
        border-radius: 6px;
      }
    '';
  };
}
