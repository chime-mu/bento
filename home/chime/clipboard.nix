{
  config,
  lib,
  pkgs,
  ...
}:
let
  clipboardAgent = pkgs.writeShellApplication {
    name = "bento-clipboard-agent";
    runtimeInputs = [
      pkgs.python3
      pkgs.wl-clipboard
    ];
    text = ''
      exec python3 ${./clipboard-agent.py} "$@"
    '';
  };
in
{
  systemd.user.services.bento-clipboard = {
    Unit = {
      Description = "Share text and PNG clipboards with the Bento Mac host";
      PartOf = [ config.wayland.systemd.target ];
      After = [ config.wayland.systemd.target ];
      ConditionEnvironment = [ "WAYLAND_DISPLAY" ];
      ConditionPathExists = [ "/dev/virtio-ports/dev.bento.clipboard" ];
    };
    Service = {
      Type = "simple";
      ExecStart = lib.getExe clipboardAgent;
      Restart = "always";
      RestartSec = 1;
    };
    Install.WantedBy = [ config.wayland.systemd.target ];
  };

  home.packages = [ clipboardAgent ];
}
