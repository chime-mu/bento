# Ghostty — installed, themed, and *not* the terminal.
#
# It was, from Phase 5 until the CPU was measured: ghostty has no desktop GL to render
# with here, so it draws through `LIBGL_ALWAYS_SOFTWARE=1` and four llvmpipe threads, and
# a near-fullscreen window with a TUI spinner in it pins a core. `$terminal` in
# home/chime/hyprland.nix carries the measurements and the tunings that did not work.
#
# So the roles are swapped and nothing else changed: this file stays exactly as it is, as
# the fallback that cannot be the reason a graphical test fails (learned/phase-3.md §8),
# and it is the right terminal again the moment there is a real GPU behind it. The only
# line that decides which of the two is *the* terminal is `$terminal` in
# home/chime/hyprland.nix.
#
# The colours come from `theme.colors.terminal` — the ANSI 16 — which foot's config
# already consumes in the same shape. That is the whole point of the third vocabulary in
# home/chime/theme/colors.nix: a terminal has no "accent", it has colour 4, and both
# terminals ask the theme the same question and get the same answer.
{ pkgs, ... }:
let
  theme = import ./theme;
  inherit (theme) colors font;
  t = colors.terminal;

  # **Ghostty is the one thing Phase 6's GPU made worse, and this is the fix.**
  #
  # Under llvmpipe it drew fine (learned/phase-5.md §6). Under VirGL it does not start at
  # all: a full-screen "Oh, no. Unable to acquire an OpenGL context for rendering."
  #
  # The reason is in `glxinfo -B` and it is a property of the whole GL stack, not of
  # ghostty. virgl here runs on ANGLE, which is a GL *ES* implementation over Metal, so
  # the guest is offered `Max GLES[23] profile version: 3.0` and
  # `Max core profile version: 0.0` — there is no desktop GL core profile behind this
  # GPU at all. llvmpipe, being a full software GL, offered one.
  #
  # And ghostty insists on desktop GL. It says so in its own startup log, overriding
  # whatever the environment asked for, so GDK_DEBUG=gl-gles does nothing:
  #
  #   warning(gtk_ghostty_application): setting GDK_DISABLE=gles-api,vulkan
  #
  # So this one process gets a software GL stack while everything else keeps the GPU.
  # `LIBGL_ALWAYS_SOFTWARE` is the same variable learned/phase-3.md §2 forbids — and the
  # prohibition is intact, because it is about the *compositor*: given it, aquamarine gets
  # an EGL device with no DRM node behind it and fails to build a renderer on every commit
  # (8504 failures, a 7.8 MB log). A client that only wants a GL context for its own
  # surface has no such problem. The variable is not wrong; setting it session-wide is.
  # Scoping is the whole point, which is why it lives on the binary and not in
  # `environment.sessionVariables`.
  #
  # Verified by sampling the scanout: the ghostty window is **96.9 % #1a1b26**, the same
  # number learned/phase-5.md §6 recorded for a working terminal under software rendering.
  #
  # symlinkJoin, not overrideAttrs: overriding the derivation would rebuild ghostty from
  # source inside the VM, which PLAN-v1 risk #2 exists to prevent. This is a trivial
  # derivation over the cached build. The desktop entry ships `Exec=ghostty` by bare name,
  # so the launcher and `$terminal` in hyprland.nix both resolve to this wrapper through
  # PATH without either of them mentioning it.
  ghostty-soft-gl = pkgs.symlinkJoin {
    name = "ghostty-soft-gl";
    paths = [ pkgs.ghostty ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/ghostty --set LIBGL_ALWAYS_SOFTWARE 1
    '';

    # symlinkJoin builds a fresh derivation and does **not** inherit `meta` from what it
    # joins, so without this every evaluation warns that `lib.getExe` is guessing the main
    # program's name — twice, from home-manager's ghostty module. Carrying the original
    # meta forward also keeps the licence and description attached to what is, after all,
    # still ghostty.
    meta = pkgs.ghostty.meta // {
      mainProgram = "ghostty";
    };
  };

  # Ghostty writes colours as `#rrggbb`; the theme stores bare hex because hyprlang wants
  # it that way inside `rgb()`. `colors.css` is the same set with the `#` already on.
  c = colors.css;

  # `palette` is a repeated key — `palette = 0=#1a1b26`, sixteen times. home-manager's
  # ghostty module builds the file with `listsAsDuplicateKeys`, so a Nix list of strings
  # is exactly the right shape and no manual line-joining is needed.
  paletteEntry = index: value: "${toString index}=#${value}";
in
{
  programs.ghostty = {
    enable = true;

    # See the comment on ghostty-soft-gl above: ghostty demands a desktop GL context and
    # VirGL/ANGLE offers only GLES, so this one binary renders on llvmpipe.
    package = ghostty-soft-gl;

    # A named theme file rather than `background`/`foreground`/`palette` inline in the
    # main config. Ghostty resolves `theme = bento` out of
    # $XDG_CONFIG_HOME/ghostty/themes, so the palette is one file with one job and the
    # config above it stays readable — and a second bento theme is a second file here,
    # not a rewrite of the settings block.
    themes.bento = {
      palette = [
        (paletteEntry 0 t.black)
        (paletteEntry 1 t.red)
        (paletteEntry 2 t.green)
        (paletteEntry 3 t.yellow)
        (paletteEntry 4 t.blue)
        (paletteEntry 5 t.magenta)
        (paletteEntry 6 t.cyan)
        (paletteEntry 7 t.white)
        (paletteEntry 8 t.brightBlack)
        (paletteEntry 9 t.brightRed)
        (paletteEntry 10 t.brightGreen)
        (paletteEntry 11 t.brightYellow)
        (paletteEntry 12 t.brightBlue)
        (paletteEntry 13 t.brightMagenta)
        (paletteEntry 14 t.brightCyan)
        (paletteEntry 15 t.brightWhite)
      ];

      background = c.background;
      foreground = c.foreground;
      cursor-color = c.accent;
      cursor-text = c.background;
      selection-background = c.overlay;
      selection-foreground = c.foreground;
    };

    settings = {
      theme = "bento";

      # `monoStrict` — the "Mono" Nerd Font patch, every glyph squeezed into one cell.
      # Same reasoning as foot: a terminal grid with a double-width icon in it is a grid
      # that no longer lines up. The bar wants the other family (home/chime/theme).
      font-family = font.monoStrict;
      font-size = 11;

      window-padding-x = 10;
      window-padding-y = 10;
      # Ghostty's own padding is what the window ends up with; balancing it stops the last
      # row of cells sitting flush against the frame when the height is not a multiple of
      # the cell size.
      window-padding-balance = true;

      # Hyprland draws the border and there is no title bar to put anywhere useful on a
      # tiling desktop. Leaving this at `auto` gets libadwaita's client-side decorations,
      # which on Hyprland means a header bar *inside* our own 2px accent border.
      window-decoration = "none";

      cursor-style = "bar";
      # A cursor that stops blinking is a cursor that a screenshot can miss. This machine
      # is inspected through screenshots (scripts/vm-screenshot.sh), so anything that
      # renders on a timer is a thing that will eventually be reported as missing — the
      # same lesson learned/phase-4.md §5 records for hyprlock's `fade_on_empty`.
      cursor-style-blink = false;

      mouse-hide-while-typing = true;

      # This is a dev VM with no session to lose. A confirmation dialog on close is one
      # more GTK 4 surface between an agent and the thing it is testing.
      confirm-close-surface = false;

      # The resize indicator is a full-screen overlay that appears on every window
      # geometry change — including the one Hyprland performs when the window first maps.
      # On llvmpipe it is a visible flash, and in a screenshot it is a number floating over
      # the terminal you were trying to photograph.
      resize-overlay = "never";

      shell-integration = "detect";
      shell-integration-features = "cursor,sudo,title";
    };
  };
}
