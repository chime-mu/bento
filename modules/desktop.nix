# The graphical session: Hyprland, and enough of a login path to land in it.
#
# Host-agnostic, like core.nix — the one thing that is *not* true of every bento machine is
# software rendering, so that hangs off `bento.desktop.softwareRendering`, which
# hosts/bento-vm/default.nix turns on. See learned/phase-0.md §2 for why the VM has no
# choice: the host's QEMU has no OpenGL compiled in at all.
#
# `programs.hyprland.enable` is doing more work here than it looks. Through
# nixos/modules/programs/wayland/wayland-session.nix it also pulls in polkit, dconf,
# xwayland, the xdg portals (hyprland's own plus the gtk one) and
# `services.graphical-desktop`, and *that* in turn defaults on `hardware.graphics`,
# `fonts.enableDefaultPackages` and pipewire with alsa+pulse. So the plan's "pipewire,
# xdg-desktop-portal-hyprland, polkit" are already satisfied by the single line below;
# restating them would only be three more places to keep in sync.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # The capability wrapper, not the store path: nixos/modules/programs/wayland/hyprland.nix
  # installs Hyprland through `security.wrappers` with cap_sys_nice, which is what lets it
  # give itself SCHED_RR at startup. Launching ${pkgs.hyprland}/bin/Hyprland directly — as
  # most greetd examples do — silently drops that.
  hyprland = "${config.security.wrapperDir}/Hyprland";
in
{
  options.bento.desktop.softwareRendering = lib.mkEnableOption ''
    the assumption that this machine has no usable GPU, so the desktop is rendered on the
    CPU (llvmpipe).

    A statement about the *hardware*, which the host makes and the desktop reacts to —
    home/chime/hyprland.nix reads it through home-manager's `osConfig` and drops the
    effects that cost a full-screen shader pass each frame: animations, blur, shadows,
    hardware cursors.

    It deliberately sets no environment variables. Nothing has to be told to fall back:
    mesa reaches llvmpipe by itself once the GPU refuses a GL context, and the two
    variables that PLAN-v1 §3 asks for turn out to be one no-op and one active regression
    (see the sessionVariables comment below, and learned/phase-3.md §2)
  '';

  config = {
    programs.hyprland.enable = true;

    # pipewire arrives via services.graphical-desktop (see the header), but rtkit does not,
    # and without it pipewire cannot take the realtime priority it asks for.
    security.rtkit.enable = true;

    # The one thing hyprlock cannot do for itself. It authenticates through PAM, and with
    # no `/etc/pam.d/hyprlock` it falls back to shelling out to `su` — which on this
    # machine means the correct password is rejected, from a screen you cannot leave.
    #
    # This is the *only* line taken from nixpkgs' `programs.hyprlock` module. Enabling the
    # whole module would also install hyprlock system-wide and turn on the NixOS
    # `services.hypridle`, giving us a second idle daemon racing the home-manager one over
    # the same session (home/chime/lock.nix). The config belongs to the user; the PAM
    # stack is the only part that has to be the machine's.
    security.pam.services.hyprlock = { };

    # Autologin straight into Hyprland: this is a dev VM whose whole premise is an agent
    # rebuilding it, and a password wall in front of the desktop only stands between the
    # agent and the thing it is meant to verify.
    #
    # `initial_session` is the autologin, and it fires once, at boot. `default_session` is
    # the greeter that runs *afterwards* — agreety, greetd's built-in text greeter, which
    # asks for the password and then starts the same Hyprland. Without it, quitting
    # Hyprland would leave tty1 dead until someone ran `systemctl restart greetd` over ssh.
    #
    # The module's `restart` option defaults to false whenever `initial_session` is set, on
    # purpose: restarting greetd re-triggers the autologin, so a Hyprland that crashes at
    # startup would relaunch forever instead of leaving the failure visible.
    services.greetd = {
      enable = true;
      settings = {
        initial_session = {
          command = hyprland;
          user = "chime";
        };
        default_session.command = "${lib.getExe' pkgs.greetd "agreety"} --cmd ${hyprland}";
      };
    };

    environment.systemPackages = with pkgs; [
      # The terminal for Phase 3. PLAN-v1 makes Ghostty the daily driver in Phase 5 and
      # keeps foot as the fallback; foot lands first because it is small, has no GPU
      # expectations at all, and gives the Super+Return acceptance criterion something to
      # open that cannot itself be the reason the criterion fails.
      foot

      # How an agent with no screen sees the screen: `grim` writes the compositor's own
      # output to a PNG over ssh. (The host can also read the QEMU scanout with a QMP
      # `screendump`, which is the same picture one layer further out — see
      # scripts/vm-screenshot.sh.)
      grim
      wl-clipboard

      # `wayland-info` prints the compositor's globals; it is the quickest answer to "is
      # this a real Wayland session and what does it advertise?".
      wayland-utils

      # home-manager's Hyprland module reloads a live session after a rebuild with
      # `hyprctl instances -j | jq ...`, calling jq by bare name. Without it on PATH that
      # hook fails on every rebuild that happens while the desktop is running. (Phase 5
      # wants jq for the agent anyway.)
      jq
    ];

    # Wayland hints for the toolkits. Chromium/Electron/Firefox/Qt need these on bare metal
    # too, so they are not gated behind softwareRendering — PLAN-v1 §3 only groups them
    # with the VM-specific settings because they arrived together in try-omarchy's single
    # environment.d file (learned/phase-0.md §3).
    #
    # environment.sessionVariables lands in /etc/pam/environment, which pam_env applies to
    # every PAM session — greetd's included. That is what makes it the right home for these
    # rather than /etc/profile, which a session started by a display manager never sources.
    #
    # **Neither software-rendering variable PLAN-v1 §3 asks for is set here, and both
    # omissions were measured — see learned/phase-3.md §2.**
    #
    #   WLR_RENDERER_ALLOW_SOFTWARE  is read by nothing. Hyprland 0.56 has no wlroots in
    #     it at all; it renders through aquamarine, whose knobs are all `AQ_*`. The string
    #     does not appear anywhere in Hyprland's link closure.
    #   LIBGL_ALWAYS_SOFTWARE        is actively harmful. Setting it makes mesa hand back
    #     an EGL device with no DRM node, aquamarine then fails to match a renderer to
    #     /dev/dri/card0, and it retries on every commit: 8504 renderer failures and a
    #     7.8 MB log in two minutes. Left unset, aquamarine fails once on the primary node
    #     (no VirGL, so `DRI2: failed to create screen`), falls back to the render node,
    #     and mesa picks llvmpipe on its own — which is the renderer we wanted, arrived at
    #     by the path the compositor is designed to take.
    environment.sessionVariables = {
      OZONE_PLATFORM = "wayland";
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
      MOZ_ENABLE_WAYLAND = "1";
      QT_QPA_PLATFORM = "wayland";
    };
  };
}
