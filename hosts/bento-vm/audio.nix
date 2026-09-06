{ lib, pkgs, ... }:
let
  audioAgent = pkgs.writeShellApplication {
    name = "bento-audio-agent";
    runtimeInputs = [
      pkgs.python3
      pkgs.pulseaudio
    ];
    text = ''
      exec python3 ${./audio-agent.py} "$@"
    '';
  };
in
{
  # Only the interactive desktop user may request a host input/output route.
  services.udev.extraRules = ''
    SUBSYSTEM=="virtio-ports", ATTR{name}=="dev.bento.audio", GROUP="audio", MODE="0660"
  '';
  users.users.chime.extraGroups = [ "audio" ];

  systemd.user.services.bento-audio-bridge = {
    description = "Expose Mac audio devices in Bento";
    wantedBy = [ "default.target" ];
    after = [
      "pipewire.service"
      "pipewire-pulse.service"
      "wireplumber.service"
    ];
    wants = [
      "pipewire.service"
      "pipewire-pulse.service"
      "wireplumber.service"
    ];
    unitConfig.ConditionPathExists = "/dev/virtio-ports/dev.bento.audio";
    serviceConfig = {
      ExecStart = lib.getExe audioAgent;
      Restart = "on-failure";
      RestartSec = 1;
    };
  };

  # QEMU advances Intel HDA's DMA position from a 100 Hz timer. A 4096-frame
  # graph quantum prevents PipeWire from treating those coarse jumps as xruns.
  services.pipewire.configPackages = [
    (pkgs.writeTextDir "share/pipewire/pipewire.conf.d/90-bento-hda-quantum.conf" ''
      context.properties = {
        default.clock.quantum     = 4096
        default.clock.min-quantum = 4096
        default.clock.max-quantum = 4096
      }

      context.properties.rules = [
        { matches = [ { cpu.vm.name = !null } ]
          actions = { update-props = { default.clock.min-quantum = 4096; }; }
        }
      ]
    '')
  ];

  environment.systemPackages = [
    audioAgent
    pkgs.pavucontrol
  ];
}
