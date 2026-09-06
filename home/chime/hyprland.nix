# Hyprland's user configuration: what the keyboard does, and how the compositor behaves on
# a machine with no GPU.
#
# The compositor itself is installed by the NixOS module (modules/desktop.nix), so both
# `package` and `portalPackage` are null here — home-manager then writes the config file
# and the systemd session target and installs nothing. Setting them would put a second,
# separately-built Hyprland in the user profile and let `Hyprland` mean different binaries
# depending on PATH order.
{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  theme = import ./theme;
  inherit (theme) colors;

  # home-manager sees the NixOS configuration as `osConfig`, which is how a *user* setting
  # can key off a *machine* fact. Both uses below are the same question — "is there a GPU?"
  # — and answering it from the host rather than hardcoding it is what keeps this file
  # correct when bento eventually boots on real hardware.
  softwareRendering = osConfig.bento.desktop.softwareRendering;
  dynamicDisplay = osConfig.bento.desktop.dynamicDisplay;

  # QEMU's Cocoa frontend refreshes virtio-gpu's EDID whenever its backing-pixel
  # geometry changes. Hyprland 0.56/Aquamarine 0.14 retain a stale mode cache for an
  # already-connected DRM output, so this helper decodes the fresh detailed timing
  # and applies it as an explicit modeline. It also computes a clean fractional scale
  # from the EDID density. Keep the implementation in a plain file so its parser and
  # event filtering can be unit-tested without evaluating a Nix derivation first.
  displaySync = pkgs.writeShellApplication {
    name = "bento-display-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.python3
      pkgs.systemd
    ];
    text = builtins.readFile ./display-sync.sh;
  };

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

  # A small, searchable equivalent of Omarchy's Super+K cheat sheet. Keep the contents
  # here beside the binds they document: it is intentionally a curated overview rather
  # than a parser for generated hyprland.conf. Walker's dmenu mode gives it the same UI as
  # the launcher without making a selection perform an action.
  keybindingsMenu = pkgs.writeShellApplication {
    name = "bento-keybindings";
    text = ''
      exec ${lib.getExe pkgs.walker} \
        --dmenu \
        --nohints \
        --hideqa \
        --placeholder "Bento key bindings" <<'BINDINGS'
      ⌘ K — Show key bindings
      ⌘ Return — Open terminal
      ⌘ B — Open browser
      ⌘ Space — Open launcher
      ⌘ W — Close window
      ⌘ F — Toggle fullscreen
      ⌘ V — Toggle floating
      ⌘ J — Toggle split direction
      ⌘ P — Toggle pseudo tiling
      ⌘ ←/↑/↓/→ — Move focus
      ⌘ Shift ←/↑/↓/→ — Swap windows
      ⌘ 1…0 — Switch workspace
      ⌘ Shift 1…0 — Move window to workspace
      ⌘ Shift S — Save screenshot
      ⌘ L — Lock
      ⌘ Shift Q — End desktop session
      ⌘ Left-drag — Move window
      ⌘ Right-drag — Resize window
      BINDINGS
    '';
  };
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
      # Phase 5's one-line change, exactly as learned/phase-3.md §8 promised: every bind
      # below follows this variable. `foot` is still installed and still themed
      # (home/chime/foot.nix) — it is the fallback that cannot be the reason a graphical
      # test fails, and putting it back is editing this line.
      "$terminal" = "ghostty";
      # Phase 5's browser. `xdg-open` resolves to the same binary through
      # home/chime/chromium.nix's mimeApps entry, so the key and the URL handler cannot
      # drift apart.
      "$browser" = "chromium";
      # Phase 4's launcher. walker runs as a GApplication service (home/chime/walker.nix),
      # so this is a message to a process that is already up, not a cold GTK4 start.
      "$launcher" = "walker";
      # Output-agnostic on purpose. This is the safe rule before the session service runs
      # and for unpatched software QEMU; bento-display-sync replaces the same catch-all
      # rule with the live EDID modeline and computed Retina scale. Never name Virtual-1.
      monitor = ",preferred,auto,1";

      # Hyprland writes *none* of its own messages to the log file by default — only
      # aquamarine, which has a separate logger, keeps writing, so the file fills with
      # libinput debounce noise while the lines that matter (an invalid kb_layout, for one)
      # are silently dropped. Turning this off is what makes the log worth opening.
      debug.disable_logs = false;

      general = {
        gaps_in = 4;
        gaps_out = 8;
        border_size = 2;
        layout = "dwindle";

        # Tokyo Night, through the role names in home/chime/theme/colors.nix. The active
        # border is a two-stop gradient — hyprlang's own syntax, one string, not a list.
        "col.active_border" = "${colors.rgba colors.hex.accent "ff"} ${colors.rgba colors.hex.accentAlt "ff"} 45deg";
        "col.inactive_border" = colors.rgba colors.hex.border "aa";
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
        # Off as of Phase 4, in the same commit that lands hyprpaper and the wallpaper —
        # which is the condition learned/phase-3.md §8 attached to turning it off. Through
        # Phase 3 the logo was the only mark on an empty screen that distinguished "the
        # compositor is running" from "the VM hung during boot"; now the wallpaper and the
        # bar answer that question, and better.
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
      };

      # Hyprland opens a "Hyprland updated to X!" window on the first session after a
      # version bump, and a periodic donation nag. Both are hyprtoolkit windows, and
      # through Phases 3-5 neither could be drawn at all — hyprtoolkit asks the GBM
      # allocator for ABGR16161616F, which virtio-gpu did not offer, and died on the null
      # (learned/phase-4.md §3). Phase 6's GL makes them work, and the first thing the
      # update window did was park itself in the middle of every screenshot.
      #
      # Off for the same reason hyprlock's `fade_on_empty` and ghostty's `resize-overlay`
      # are off: on a machine inspected through screenshots, anything that covers the
      # desktop on its own schedule will eventually be reported as a bug in the desktop.
      ecosystem = {
        no_update_news = true;
        no_donation_nag = true;
      };

      cursor = {
        # Cocoa composites the visible host cursor outside the guest scanout, giving it
        # native latency. Hide Hyprland's copy or resizing/fullscreen transitions show two
        # pointers. On a future non-Cocoa host dynamicDisplay stays false.
        invisible = dynamicDisplay;

        # There is no hardware cursor plane under llvmpipe. Left to its own devices
        # Hyprland probes for one, and the failure shows up as a stuttering pointer.
        no_hardware_cursors = softwareRendering;
      };

      input = {
        # The host is a Danish Mac. QEMU's virtio keyboard forwards raw scancodes rather
        # than the host's resolved characters, so the layout has to be named again here or
        # the guest reads a Danish keyboard as US.
        kb_layout = "dkmac";
        # Both Option keys chose level 3, as macOS does; xkb's default gives it to the
        # right one alone, so Left-Option would otherwise be dead for symbols.
        kb_options = "lv3:alt_switch";
        follow_mouse = 1;
        # QEMU's usb-tablet sends absolute coordinates, so pointer acceleration would be
        # applied to a position that is already exactly where the host's cursor is.
        accel_profile = "flat";
      };

      # Omarchy's scheme. Super+B is bound as of Phase 5 — through Phase 4 it was
      # deliberately absent rather than bound to a placeholder, so that a key which did
      # nothing meant "not built yet" instead of "broken".
      bind = [
        # macOS does not reserve Command+K, which makes this cheat sheet reachable even
        # on releases where Command+Space is consumed by Spotlight ahead of QEMU.
        "$mod, K, exec, ${lib.getExe keybindingsMenu}"
        "$mod, RETURN, exec, $terminal"
        "$mod, B, exec, $browser"
        "$mod, SPACE, exec, $launcher"
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

        # Locks now. hypridle locks on its own after 30 minutes (home/chime/lock.nix);
        # this is the deliberate one. It goes through logind rather than calling hyprlock
        # directly so that both routes into the lock screen are the same code path —
        # hypridle owns `lock_cmd` and answers logind's Lock signal.
        "$mod, L, exec, loginctl lock-session"

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

  # Home Manager's Hyprland integration reaches this target only after importing
  # WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE into systemd. The helper applies
  # the current EDID immediately, then monitors DRM hotplug changes; its own retry loop
  # recreates udevadm if the monitor exits, while Restart covers an unexpected helper exit.
  systemd.user.services = lib.optionalAttrs dynamicDisplay {
    bento-display-sync = {
      Unit = {
        Description = "Synchronize Hyprland with Bento's Cocoa display";
        PartOf = [ config.wayland.systemd.target ];
        After = [ config.wayland.systemd.target ];
        ConditionEnvironment = [ "HYPRLAND_INSTANCE_SIGNATURE" ];
      };

      Service = {
        Type = "simple";
        ExecStart = lib.getExe displaySync;
        Restart = "on-failure";
        RestartSec = 1;
      };

      Install.WantedBy = [ config.wayland.systemd.target ];
    };
  };

  # The screenshot bind writes here, and grim will not create the directory itself.
  home.packages = [ keybindingsMenu ] ++ lib.optionals dynamicDisplay [ displaySync ];
  home.file."Pictures/.keep".text = "";
}
