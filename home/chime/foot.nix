# foot — the terminal, until Phase 5 makes it ghostty.
#
# PLAN-v1 puts terminal theming in Phase 5, with ghostty. This file exists anyway, because
# Phase 4's goal is that the desktop *looks* like one thing, and the terminal is the only
# window there is anything to open: an unthemed foot on a Tokyo Night desktop is the one
# surface that gives the game away. It is also where `theme.colors.terminal` — the ANSI 16
# — gets its first consumer, and ghostty will want exactly the same list.
#
# **The package moved here from `modules/desktop.nix`.** home-manager's `programs.foot` has
# no nullable `package`, so leaving foot in `environment.systemPackages` as well would put
# two builds of it on PATH and make `foot` mean whichever came first — the same trap
# learned/phase-3.md §5 describes for Hyprland. `home-manager.useUserPackages` installs to
# `/etc/profiles/per-user/chime`, which NixOS puts on the session PATH, so `$terminal =
# "foot"` in home/chime/hyprland.nix resolves exactly as before.
{ ... }:
let
  theme = import ./theme;
  inherit (theme) colors font;
  t = colors.terminal;
in
{
  programs.foot = {
    enable = true;

    settings = {
      main = {
        # `monoStrict` — the "Mono" patch, every glyph forced into one cell. That is wrong
        # for a status bar (home/chime/theme explains why) and right here: a terminal grid
        # with a double-width icon in it is a terminal grid that no longer lines up.
        font = "${font.monoStrict}:size=11";
        pad = "10x10 center";
        # The QEMU display reports no sensible physical size, so DPI-derived font scaling
        # produces an arbitrary result. Scale from the compositor instead.
        dpi-aware = "no";
      };

      cursor.style = "beam";

      # **`[colors-dark]`, not `[colors]`.** foot grew a light/dark theme pair; the old
      # section still works but prints `deprecated: foot: [colors]: use [colors-dark]
      # instead` — once per key, so a 20-colour palette greets you with twenty lines of
      # warning at the top of every terminal. There is no `colors-light` here on purpose:
      # bento is a dark desktop, and an unused half-theme is a second thing to keep in
      # step with `home/chime/theme`.
      #
      # foot writes hex without a leading '#', which is why the theme keeps the bare form.
      colors-dark = {
        alpha = 1.0;

        # The cursor's colours belong to the *palette*, not to `[cursor]` — that section
        # is style only, and `[cursor] color = …` is rejected outright: "not a valid
        # option: color", printed into the terminal it failed to configure. Two values:
        # the text under the cursor, then the cursor itself.
        cursor = "${colors.hex.background} ${colors.hex.accent}";
        background = colors.hex.background;
        foreground = colors.hex.foreground;

        regular0 = t.black;
        regular1 = t.red;
        regular2 = t.green;
        regular3 = t.yellow;
        regular4 = t.blue;
        regular5 = t.magenta;
        regular6 = t.cyan;
        regular7 = t.white;

        bright0 = t.brightBlack;
        bright1 = t.brightRed;
        bright2 = t.brightGreen;
        bright3 = t.brightYellow;
        bright4 = t.brightBlue;
        bright5 = t.brightMagenta;
        bright6 = t.brightCyan;
        bright7 = t.brightWhite;

        selection-background = colors.hex.overlay;
        selection-foreground = colors.hex.foreground;
      };
    };
  };
}
