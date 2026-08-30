# The whole visual theme, as data: `let theme = import ./theme; in theme.colors.css.accent`.
#
# Colours are big enough to deserve their own file (PLAN-v1 §4 step 3 names `colors.nix`
# explicitly); the font family and the wallpaper are one line each and live here rather
# than in a file called "colors".
#
# This is deliberately a plain expression and not a home-manager module. Nothing here is
# an option to be merged or overridden — it is the input the modules read, and keeping it
# outside the module system means a theme switcher can `import` it without evaluating a
# configuration.
{
  colors = import ./colors.nix;

  font = {
    # The family fontconfig resolves to; verified with `fc-scan` against
    # nerd-fonts.caskaydia-mono, which advertises exactly these three families.
    #
    # `mono` is the variable-advance patch: the Nerd Font glyphs are drawn at their natural
    # width, which is what a status bar wants. `monoStrict` forces every glyph, icons
    # included, into one cell — right for a terminal, wrong for a bar, where it clips the
    # wider symbols.
    mono = "CaskaydiaMono Nerd Font";
    monoStrict = "CaskaydiaMono Nerd Font Mono";
    propo = "CaskaydiaMono Nerd Font Propo";

    size = 12;
  };

  # A path, so Nix copies the PNG into the store and every consumer gets the same
  # immutable path. Regenerate with `python3 scripts/make-wallpaper.py`.
  wallpaper = ./tokyo-night.png;
}
