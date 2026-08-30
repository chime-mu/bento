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

  # Nerd Font glyphs, named, and written as **codepoints rather than pasted characters**.
  #
  # The obvious way to do this is to paste  and  straight into the string. Do not: they
  # are U+F085 and U+F1C0, in the Private Use Area, and they survive a round trip through
  # an editor, a terminal, a diff or an agent's file writer only by luck. The first attempt
  # at this file lost every one of them silently — the config reached the guest with the
  # spaces intact and the glyphs gone, and the bar rendered `11%` with a gap in front of it
  # and no error anywhere to say why.
  #
  # A codepoint cannot be lost that way, and it also says which glyph is meant to a reader
  # whose terminal has no Nerd Font. `builtins.fromJSON` is the escape hatch: Nix string
  # literals have no `\uXXXX`, JSON does.
  #
  # Verified present in nerd-fonts.caskaydia-mono with
  # `fc-list ":charset=f085" family`. These are all original Font Awesome 4 glyphs, the
  # oldest and most stable layer of the Nerd Font patch.
  icons =
    let
      glyph = code: builtins.fromJSON ''"\u${code}"'';
    in
    {
      cpu = glyph "f085"; # cogs
      memory = glyph "f1c0"; # database
      network = glyph "f0ac"; # globe
      networkOff = glyph "f127"; # chain-broken
      lock = glyph "f023"; # lock
      bell = glyph "f0f3"; # bell
    };

  # A path, so Nix copies the PNG into the store and every consumer gets the same
  # immutable path. Regenerate with `python3 scripts/make-wallpaper.py`.
  wallpaper = ./tokyo-night.png;
}
