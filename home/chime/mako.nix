# Mako — notifications.
#
# One thing here is not in home-manager's module and has to be: **the systemd unit**.
# `services.mako.enable` installs the package and puts mako's D-Bus service file in
# `~/.local/share/dbus-1/services`, and that file says
#
#     Name=org.freedesktop.Notifications
#     SystemdService=mako.service
#
# so the first `notify-send` asks the bus for the notification server, the bus hands the
# request to systemd, and systemd has no `mako.service` — mako ships one in
# `share/systemd/user/`, but that directory is only read for packages in the *system*
# `systemd.packages`, and mako is a home package. The notification is dropped with a
# D-Bus error and nothing on screen explains why. The unit below closes that gap, and
# also starts mako up front rather than at the first notification, which is what you want
# for a daemon whose whole job is to already be listening.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  theme = import ./theme;
  inherit (theme) colors font;
in
{
  services.mako = {
    enable = true;

    settings = {
      font = "${font.mono} ${toString font.size}";

      # Top-right, clear of waybar (34 px tall) rather than under it.
      anchor = "top-right";
      layer = "overlay";
      margin = "10";
      padding = "12";
      width = 380;
      height = 160;

      border-size = 1;
      border-radius = 10;

      background-color = "${colors.css.background}f2";
      text-color = colors.css.foreground;
      border-color = colors.css.border;
      progress-color = "over ${colors.css.accent}";

      default-timeout = 6000;
      ignore-timeout = false;
      max-visible = 5;
      # By summary, not by app-name. Grouping on the app collapses *everything* one
      # program says into a single bubble with a counter — measured: two unrelated
      # `notify-send` messages became "(2) Critical" and the first one's text was simply
      # not on screen. By summary, a repeated notification still collapses (which is the
      # point) and two different ones stay two.
      group-by = "summary";

      icons = true;
      max-icon-size = 48;
      markup = true;
      actions = true;
      format = "<b>%s</b>\\n%b";

      # Sections. home-manager writes any attrset-valued key as a `[criteria]` block, so
      # the attribute *name* is the criteria expression.
      "urgency=low" = {
        border-color = colors.css.muted;
        text-color = colors.css.foregroundDim;
        default-timeout = 4000;
      };

      "urgency=critical" = {
        border-color = colors.css.urgent;
        text-color = colors.css.foreground;
        # Critical means "still there when you come back": no timeout at all.
        default-timeout = 0;
      };
    };
  };

  # See the header. `Type = "dbus"` with the well-known name is what lets an activation
  # request from the bus be satisfied by *this* unit — and it also means an eager start
  # here and a bus activation later cannot end up with two makos.
  systemd.user.services.mako = {
    Unit = {
      Description = "mako notification daemon";
      Documentation = [ "man:mako(1)" ];
      PartOf = [ config.wayland.systemd.target ];
      After = [ config.wayland.systemd.target ];
      ConditionEnvironment = [ "WAYLAND_DISPLAY" ];
    };

    Service = {
      Type = "dbus";
      BusName = "org.freedesktop.Notifications";
      ExecStart = lib.getExe pkgs.mako;
      ExecReload = "${lib.getExe' pkgs.mako "makoctl"} reload";
      Restart = "on-failure";
    };

    Install.WantedBy = [ config.wayland.systemd.target ];
  };

  # `notify-send`. mako is the server; nothing in the closure so far is a *client*, so
  # without this the acceptance test for this phase has no way to send a notification.
  home.packages = [ pkgs.libnotify ];
}
