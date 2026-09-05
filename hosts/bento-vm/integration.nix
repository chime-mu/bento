{ lib, pkgs, ... }:
let
  mountMac = pkgs.writeShellApplication {
    name = "bento-mount-mac";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      util-linux
    ];
    text = builtins.readFile ./mount-mac.sh;
  };
in
{
  # QEMU exposes the private clipboard channel under /dev/virtio-ports. Only the
  # explicitly pinned primary users group can open it.
  services.udev.extraRules = ''
    SUBSYSTEM=="virtio-ports", ATTR{name}=="dev.bento.clipboard", GROUP="users", MODE="0660"
  '';

  systemd.services.bento-mac-mount = {
    description = "Mount Bento's optional Mac folder";
    wantedBy = [ "multi-user.target" ];
    after = [
      "local-fs.target"
      "systemd-udev-settle.service"
    ];
    wants = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe mountMac;
      ExecStop = "${lib.getExe mountMac} --stop";
      RemainAfterExit = true;
      StateDirectory = "bento-mac-mount";
      StateDirectoryMode = "0700";
    };
  };

  environment.systemPackages = [ mountMac ];
}
