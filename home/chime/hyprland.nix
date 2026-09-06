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

  # The helpers that make the Lua config below readable.
  #
  # home-manager renders `settings.<name>` as `hl.<name>(...)`, and an entry carrying
  # `_args` as a multi-argument call. Every argument is passed through
  # `lib.generators.toLua`, so a Nix string arrives in Lua as a *quoted string* and only
  # `mkLuaInline` arrives as an expression. That is the whole grammar: `luaExpr` for
  # something Lua must evaluate (a local, a dispatcher), `luaString` for a value Nix knows
  # and Lua should not interpret (a store path, a shell command with its own quotes).
  luaExpr = lib.generators.mkLuaInline;
  luaString = lib.generators.toLua { };

  # `mod` is a Lua local declared in `settings.mod` below, so key strings are concatenated
  # in Lua rather than in Nix. That is the same indirection hyprlang's `$mod` gave us, and
  # it keeps "which modifier is the Bento key" a one-line change in one place.
  mkBind = keys: dispatcher: {
    _args = [
      (luaExpr ''mod .. " + ${keys}"'')
      (luaExpr dispatcher)
    ];
  };

  mkExec = command: "hl.dsp.exec_cmd(${luaString command})";

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
      (mkBind key "hl.dsp.focus({ workspace = ${ws} })")
      (mkBind "SHIFT + ${key}" "hl.dsp.window.move({ workspace = ${ws} })")
    ]
  ) (lib.range 0 9);

  # A small, searchable equivalent of Omarchy's Super+K cheat sheet. Keep the contents
  # here beside the binds they document: it is intentionally a curated overview rather
  # than a parser for the generated hyprland.lua. Walker's dmenu mode gives it the same UI
  # as the launcher without making a selection perform an action.
  keybindingsMenu = pkgs.writeShellApplication {
    name = "bento-keybindings";
    text = ''
      exec ${lib.getExe pkgs.walker} \
        --dmenu \
        --nohints \
        --hideqa \
        --placeholder "Bento key bindings" <<'BINDINGS'
      ⌘ K — Show key bindings
      ⌘ Escape — System menu (lock, log out, reboot, shut down)
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

  # Omarchy's System menu, which is where its Logout lives. Theirs is a route inside one
  # big menu driven by a Quickshell plugin (`omarchy-shell shell summon omarchy.menu`)
  # over a JSONC definition; that is a large dependency for four lines of shell, and this
  # repo already has the same UI for free in walker's dmenu mode. So the structure is
  # borrowed and the machinery is not — the entries and their order are theirs
  # (Lock, Suspend, Logout, Reboot, Shutdown), minus the ones this VM has no answer for.
  #
  # Two of the actions deliberately go the long way round:
  #
  #   Lock is `loginctl lock-session`, not hyprlock, for the reason the Super+L bind
  #   already gives below — hypridle owns `lock_cmd` and answers logind's Lock signal, so
  #   every route into the lock screen stays one code path.
  #
  #   Logout is `hyprctl dispatch 'hl.dsp.exit()'` and not `hyprctl dispatch exit`. Under
  #   the Lua config manager a dispatcher argument is evaluated as Lua; the old spelling
  #   fails at runtime with no output anyone would see from a launcher
  #   (learned/hyprland-lua.md §3).
  #
  # No Suspend: this is a guest whose host window is the display, and `systemctl suspend`
  # inside it is not the same gesture as sleeping the Mac. No confirmation step either,
  # which is Omarchy's behaviour — say so if a mistyped Enter on Shut down turns out to
  # cost more than the second it saves.
  systemMenu = pkgs.writeShellApplication {
    name = "bento-system";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      choice=$(${lib.getExe pkgs.walker} \
        --dmenu \
        --nohints \
        --hideqa \
        --placeholder "Bento system" <<'ACTIONS'
      Lock
      Log out
      Reboot
      Shut down
      ACTIONS
      ) || exit 0

      case "$choice" in
        "Lock") loginctl lock-session ;;
        "Log out") hyprctl dispatch 'hl.dsp.exit()' ;;
        "Reboot") systemctl reboot ;;
        "Shut down") systemctl poweroff ;;
        *) exit 0 ;;
      esac
    '';
  };
in
{
  wayland.windowManager.hyprland = {
    enable = true;
    package = null;
    portalPackage = null;

    # Lua, because 0.56 prints "You are using the .conf config format, support for which
    # will be removed in Hyprland 0.57" at every launch, and 0.57 means it. This is also
    # home-manager's own default for `home.stateVersion` 26.05 and later — ours is 26.11 —
    # so the line is now a pin against a *future* flip away from Lua rather than a reversal
    # of the current one.
    #
    # The two runtime consequences are not obvious from here, and both are load-bearing:
    #
    #   `hyprctl keyword` stops working ("keyword can't work with non-legacy parsers. Use
    #   eval.") and `hyprctl eval <lua>` starts. home/chime/display-sync.sh and
    #   scripts/vm-screenshot.sh are the two callers and both were moved with this commit.
    #   `hyprctl getoption` is unaffected and still prints `str: …`.
    #
    #   `hyprctl dispatch <name> <args>` is now evaluated as Lua, so it wants
    #   `hyprctl dispatch 'hl.dsp.exit()'`, not `hyprctl dispatch exit`.
    #
    # hyprlock and hypridle (home/chime/lock.nix) and hyprpaper keep their own .conf files.
    # The deprecation is Hyprland's config parser, not hyprlang the language.
    configType = "lua";

    # Rendered by home-manager as `hl.<attribute>(...)` calls, in the order: locals first,
    # then the rest alphabetically. See wiki.hypr.land for the Lua API, and
    # hyprland's own `share/hypr/stubs/hl.meta.lua` for the exhaustive, generated list of
    # every config key and dispatcher the running binary actually accepts.
    settings = {
      mod._var = "SUPER";
      # Phase 5's one-line change, exactly as learned/phase-3.md §8 promised: every bind
      # below follows this variable. `foot` is still installed and still themed
      # (home/chime/foot.nix) — it is the fallback that cannot be the reason a graphical
      # test fails, and putting it back is editing this line.
      terminal._var = "ghostty";
      # Phase 5's browser. `xdg-open` resolves to the same binary through
      # home/chime/chromium.nix's mimeApps entry, so the key and the URL handler cannot
      # drift apart.
      browser._var = "chromium";
      # Phase 4's launcher. walker runs as a GApplication service (home/chime/walker.nix),
      # so this is a message to a process that is already up, not a cold GTK4 start.
      launcher._var = "walker";

      # Output-agnostic on purpose. This is the safe rule before the session service runs
      # and for unpatched software QEMU; bento-display-sync replaces the same catch-all
      # rule with the live EDID modeline and computed Retina scale. Never name Virtual-1.
      monitor = {
        output = "";
        mode = "preferred";
        position = "auto";
        scale = 1;
      };

      config = {
        general = {
          gaps_in = 4;
          gaps_out = 8;
          border_size = 2;
          layout = "dwindle";

          # Tokyo Night, through the role names in home/chime/theme/colors.nix. The active
          # border is a two-stop gradient — a `{ colors, angle }` table in Lua, where
          # hyprlang wanted the stops and the angle run together into one string.
          col = {
            active_border = {
              colors = [
                (colors.rgba colors.hex.accent "ff")
                (colors.rgba colors.hex.accentAlt "ff")
              ];
              angle = 45;
            };
            inactive_border = colors.rgba colors.hex.border "aa";
          };
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
          # care about not drawing is already not drawn. Setting the old name is not
          # ignored, it is an error printed across the top of the screen at every launch.
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

        # Hyprland writes *none* of its own messages to the log file by default — only
        # aquamarine, which has a separate logger, keeps writing, so the file fills with
        # libinput debounce noise while the lines that matter (an invalid kb_layout, for
        # one) are silently dropped. Turning this off is what makes the log worth opening.
        debug.disable_logs = false;
      };

      # Omarchy's scheme. Super+B is bound as of Phase 5 — through Phase 4 it was
      # deliberately absent rather than bound to a placeholder, so that a key which did
      # nothing meant "not built yet" instead of "broken".
      bind = [
        # macOS does not reserve Command+K, which makes this cheat sheet reachable even
        # on releases where Command+Space is consumed by Spotlight ahead of QEMU.
        (mkBind "K" (mkExec (lib.getExe keybindingsMenu)))

        # Escape for the system menu, the way a power menu is usually reached. The menu is
        # also a desktop entry, so Super+Space then "system" finds it without knowing this
        # bind exists — which is the whole point, since the session had no discoverable way
        # to log out before it.
        (mkBind "ESCAPE" (mkExec (lib.getExe systemMenu)))

        (mkBind "RETURN" "hl.dsp.exec_cmd(terminal)")
        (mkBind "B" "hl.dsp.exec_cmd(browser)")
        (mkBind "SPACE" "hl.dsp.exec_cmd(launcher)")
        (mkBind "W" "hl.dsp.window.close()")
        (mkBind "F" ''hl.dsp.window.fullscreen({ mode = "fullscreen" })'')
        (mkBind "V" ''hl.dsp.window.float({ action = "toggle" })'')
        # Still a message to the dwindle layout rather than a dispatcher of its own, as it
        # became in 0.56 — `hl.dsp.layout(msg)` is the Lua spelling of `layoutmsg`, and
        # `pseudo` is still its own dispatcher, which is why only one of these two is
        # addressed to the layout.
        (mkBind "J" ''hl.dsp.layout("togglesplit")'')
        (mkBind "P" "hl.dsp.window.pseudo()")

        (mkBind "left" ''hl.dsp.focus({ direction = "left" })'')
        (mkBind "right" ''hl.dsp.focus({ direction = "right" })'')
        (mkBind "up" ''hl.dsp.focus({ direction = "up" })'')
        (mkBind "down" ''hl.dsp.focus({ direction = "down" })'')

        (mkBind "SHIFT + left" ''hl.dsp.window.swap({ direction = "left" })'')
        (mkBind "SHIFT + right" ''hl.dsp.window.swap({ direction = "right" })'')
        (mkBind "SHIFT + up" ''hl.dsp.window.swap({ direction = "up" })'')
        (mkBind "SHIFT + down" ''hl.dsp.window.swap({ direction = "down" })'')

        # Writes the whole output to a timestamped PNG. The same tool an agent uses over
        # ssh to see this desktop, bound where a human can reach it.
        (mkBind "SHIFT + S" (mkExec ''grim "$HOME/Pictures/bento-$(date +%Y%m%d-%H%M%S).png"''))

        # Locks now. hypridle locks on its own after 30 minutes (home/chime/lock.nix);
        # this is the deliberate one. It goes through logind rather than calling hyprlock
        # directly so that both routes into the lock screen are the same code path —
        # hypridle owns `lock_cmd` and answers logind's Lock signal.
        (mkBind "L" (mkExec "loginctl lock-session"))

        # Ends the session. greetd does not restart into the autologin and start-hyprland's
        # watchdog only relaunches after an *unclean* exit, so this drops to agreety's login
        # prompt rather than looping back into a new Hyprland.
        (mkBind "SHIFT + Q" "hl.dsp.exit()")
      ]
      ++ workspaceBinds
      ++ [
        # hyprlang needed a separate `bindm` keyword for these; Lua does not, because the
        # press-and-hold behaviour is a property of the *dispatcher*, not of the bind.
        # `hl.dsp.window.drag()` is Hyprland's mouse-drag action, and
        # `hl.dsp.window.resize()` **with no arguments** is the mouse-resize one — pass it
        # a size and you get the geometric `resizeactive` instead. Either way the drag ends
        # on button-up through the layout's drag controller, which is checked on every key
        # and mouse event and knows nothing about the bind.
        #
        # Upstream's own example config decorates both of these with `{ mouse = true }`.
        # That option does not exist: `hl.bind` reads `locked`, `release`, `repeating`,
        # `long_press`, `click`, `drag`, `transparent`, `ignore_mods`, `non_consuming`,
        # `dont_inhibit`, `submap_universal`, `catchall`, `allow_input_capture`, `device`
        # and `description`, and silently ignores anything else. Passing it would only look
        # like it was doing something.
        (mkBind "mouse:272" "hl.dsp.window.drag()")
        (mkBind "mouse:273" "hl.dsp.window.resize()")
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

  # What makes the system menu findable without knowing Super+Escape: elephant indexes
  # desktop entries, so this puts "System" one Super+Space and three letters away. The
  # entry has to be a *launcher* for the menu rather than four entries for the four
  # actions — "Shut down" sitting in the same list as an editor is one fuzzy match away
  # from ending the session by accident.
  #
  # `NoDisplay` is deliberately not set. home/chime/walker.nix explains why a rebuild
  # re-indexes at all: elephant's unit carries the profile paths, so adding this entry
  # changes the unit text and sd-switch restarts it. Nothing else is needed to make it
  # appear.
  xdg.desktopEntries.bento-system = {
    name = "System";
    genericName = "Lock, log out, reboot, shut down";
    comment = "Bento session and power actions";
    exec = lib.getExe systemMenu;
    icon = "system-shutdown";
    terminal = false;
    categories = [ "System" ];
  };

  # The screenshot bind writes here, and grim will not create the directory itself.
  home.packages = [
    keybindingsMenu
    systemMenu
  ] ++ lib.optionals dynamicDisplay [ displaySync ];
  home.file."Pictures/.keep".text = "";
}
