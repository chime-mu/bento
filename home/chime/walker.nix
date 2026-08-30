# Walker — the launcher on Super+Space.
#
# PLAN-v1 risk #5 pre-authorises falling back to fuzzel if walker is broken on aarch64.
# It is not: `nix build --dry-run nixpkgs#walker` on the guest reports 7 paths *fetched*,
# zero built, so walker 2.17.0 is in the aarch64-linux binary cache and no source build
# happens in the VM (which risk #2 forbids). fuzzel stays unused.
#
# Walker 2.x is two processes, which every pre-2.0 guide gets wrong: `walker` is only the
# GTK4 front end, and **elephant** is the daemon that actually knows what a desktop entry
# or a calculator expression is. Without it the launcher opens and sits there saying
# "Waiting for elephant...". home-manager models this — `services.walker.
# enableElephantIntegration` defaults to `services.elephant.enable` and adds the
# Requires=/After= — but it will not enable elephant for you.
{ ... }:
let
  theme = import ./theme;
  inherit (theme) colors font;
in
{
  services.elephant = {
    enable = true;

    # The stock package builds every provider it ships. Narrowing it with
    # `elephant.override { enabledProviders = [...]; }` would be a Go compile *inside the
    # VM* to save disk we have plenty of — exactly the trade PLAN-v1 risk #2 says not to
    # make. Providers are selected at query time below instead.
    settings.providers.default = [
      "desktopapplications"
      "calc"
      "runner"
      # Added in Phase 5: it opens its result with `xdg-open`, which now resolves to
      # chromium (home/chime/chromium.nix). Through Phase 4 this was left out precisely
      # because there was nothing to hand the URL to.
      "websearch"
    ];
  };

  services.walker = {
    enable = true;

    # Run walker as a GApplication service so Super+Space talks to a process that is
    # already up. Cold-starting GTK4 on llvmpipe for every keypress is the difference
    # between a launcher and a pause.
    systemd.enable = true;

    settings = {
      # Pressing the bind again dismisses it, rather than opening a second one.
      close_when_open = true;
      selection_wrap = true;
      keybind_symbols = true;

      providers = {
        # What a bare query searches. `runner` is added to the stock set (which is
        # applications + calc + websearch) because on a machine you are rebuilding all day
        # "run this binary" is a launcher's second job. `websearch` was dropped through
        # Phase 4 — with no browser installed it offered an action nothing could take —
        # and comes back here now that Super+B has something behind it.
        default = [
          "desktopapplications"
          "calc"
          "runner"
          "websearch"
        ];
        empty = [ "desktopapplications" ];
      };

      placeholders.default = {
        input = "Search bento";
        list = "Nothing matches";
      };
    };

    theme = {
      name = "bento";

      # Walker starts from its embedded default theme and overrides only the files a theme
      # directory actually provides (`setup_theme_from_path` in src/theme/mod.rs), so
      # supplying style.css alone is complete — the XML layouts stay the stock ones.
      #
      # The CSS, though, is *replaced* rather than layered: `setup_css` loads the embedded
      # default only when the theme has no stylesheet. So this file has to style the whole
      # widget tree, not just the colours. It follows the structure of walker's own
      # resources/themes/default/style.css.
      style = ''
        @define-color bg        ${colors.css.background};
        @define-color surface   ${colors.css.surface};
        @define-color overlay   ${colors.css.overlay};
        @define-color fg        ${colors.css.foreground};
        @define-color border    ${colors.css.border};
        @define-color accent    ${colors.css.accent};
        @define-color error_bg  ${colors.css.error};

        * {
          all: unset;
          font-family: "${font.mono}", monospace;
          font-size: ${toString (font.size + 2)}px;
        }

        scrollbar {
          opacity: 0;
        }

        .normal-icons { -gtk-icon-size: 16px; }
        .large-icons  { -gtk-icon-size: 32px; }

        .box-wrapper {
          background: @bg;
          border: 1px solid @border;
          border-radius: 14px;
          padding: 16px;
        }

        .search-container {
          border-radius: 10px;
        }

        .input {
          background: @surface;
          color: @fg;
          caret-color: @accent;
          padding: 10px 12px;
        }

        .input placeholder { opacity: 0.45; }
        .input selection    { background: @overlay; }

        .list        { color: @fg; }
        .placeholder,
        .elephant-hint,
        .preview-box { color: @fg; opacity: 0.5; }

        .item-box {
          border-radius: 8px;
          padding: 8px 10px;
        }

        /* GtkGridView rows report selection as `child:selected`; older layouts use
           `row:selected`. Both are styled so the highlight cannot silently vanish if a
           future walker swaps the widget. */
        child:selected .item-box,
        row:selected .item-box {
          background: @accent;
          color: @bg;
        }

        .item-quick-activation {
          background: @surface;
          border-radius: 5px;
          padding: 8px;
        }

        .item-subtext {
          font-size: ${toString font.size}px;
          opacity: 0.55;
        }

        .providerlist .item-subtext {
          font-size: unset;
          opacity: 0.75;
        }

        .item-image-text { font-size: 26px; }
        .calc .item-text { font-size: 24px; }
        .symbols .item-image { font-size: 24px; }

        .preview {
          border: 1px solid @border;
          border-radius: 10px;
          color: @fg;
        }

        .preview .large-icons { -gtk-icon-size: 64px; }

        .keybinds {
          padding-top: 10px;
          border-top: 1px solid @surface;
          font-size: ${toString (font.size - 1)}px;
          color: @fg;
        }

        .keybind-button        { opacity: 0.5; }
        .keybind-button:hover  { opacity: 0.8; }
        .keybind-bind          { text-transform: lowercase; opacity: 0.35; }

        .keybind-label {
          padding: 2px 4px;
          border-radius: 4px;
          border: 1px solid @border;
        }

        .error {
          padding: 10px;
          background: @error_bg;
          color: @bg;
        }

        :not(.calc).current { font-style: italic; }

        .preview-content.archlinuxpkgs,
        .preview-content.dnfpackages,
        .preview-content.aptpackages {
          font-family: monospace;
        }
      '';
    };
  };
}
