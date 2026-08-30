# Ghostty — the terminal, and the first thing Super+Return opens.
#
# `home/chime/foot.nix` stays exactly as it is. It is the fallback that cannot be the
# reason a graphical test fails (learned/phase-3.md §8), and the only line that decides
# which of the two is *the* terminal is `$terminal` in home/chime/hyprland.nix.
#
# The colours come from `theme.colors.terminal` — the ANSI 16 — which foot's config
# already consumes in the same shape. That is the whole point of the third vocabulary in
# home/chime/theme/colors.nix: a terminal has no "accent", it has colour 4, and both
# terminals ask the theme the same question and get the same answer.
{ ... }:
let
  theme = import ./theme;
  inherit (theme) colors font;
  t = colors.terminal;

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
