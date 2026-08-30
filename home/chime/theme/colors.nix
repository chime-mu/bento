# Tokyo Night — the one place a colour is written down.
#
# Two layers on purpose, and the second one is the point:
#
#   `palette` is Tokyo Night's own vocabulary (`blue7`, `fgGutter`, `comment`), taken from
#   folke/tokyonight.nvim's "night" variant. It is what the upstream theme calls things.
#
#   `hex`/`css` are *roles* — `background`, `border`, `accent`, `warn`. Every consumer
#   (waybar, walker, mako, hyprland, hyprlock) uses only these. That is the seam PLAN-v1
#   §4 step 3 asks for: a second theme is a second file exporting the same role names, and
#   nothing downstream changes. A config that reached for `palette.blue7` directly would
#   weld itself to Tokyo Night's naming and break that.
#
# Values are bare six-digit hex, no leading `#`, because hyprlang wants them that way
# inside `rgb()`/`rgba()`. `css` is the same set with the `#` for anything CSS-shaped.
#
# Imported as a plain expression (`import ./colors.nix`), so no `lib` — `builtins.mapAttrs`
# is enough and keeps this file callable from anywhere, including a future theme switcher
# that is not a module.
let
  palette = {
    bg = "1a1b26";
    bgDark = "16161e";
    bgHighlight = "292e42";
    terminalBlack = "414868";
    fg = "c0caf5";
    fgDark = "a9b1d6";
    fgGutter = "3b4261";
    dark3 = "545c7e";
    comment = "565f89";
    dark5 = "737aa2";
    blue0 = "3d59a1";
    blue = "7aa2f7";
    cyan = "7dcfff";
    blue1 = "2ac3de";
    blue2 = "0db9d7";
    blue5 = "89ddff";
    blue6 = "b4f9f8";
    blue7 = "394b70";
    magenta = "bb9af7";
    magenta2 = "ff007c";
    purple = "9d7cd8";
    orange = "ff9e64";
    yellow = "e0af68";
    green = "9ece6a";
    green1 = "73daca";
    green2 = "41a6b5";
    teal = "1abc9c";
    red = "f7768e";
    red1 = "db4b4b";
  };

  role = {
    background = palette.bg;
    backgroundAlt = palette.bgDark;
    surface = palette.bgHighlight;
    overlay = palette.fgGutter;

    foreground = palette.fg;
    foregroundDim = palette.fgDark;
    muted = palette.comment;

    border = palette.blue7;
    borderActive = palette.blue;

    accent = palette.blue;
    accentAlt = palette.magenta;

    info = palette.cyan;
    ok = palette.green;
    warn = palette.yellow;
    error = palette.red;
    urgent = palette.red1;
  };
in
{
  inherit palette;

  # Bare hex, for hyprlang and anywhere else that supplies its own wrapper.
  hex = role;

  # "#rrggbb", for GTK CSS (waybar, walker) and mako.
  css = builtins.mapAttrs (_name: value: "#${value}") role;

  # hyprlang's colour spellings. `alpha` is two hex digits: "ff" opaque, "00" clear.
  rgb = value: "rgb(${value})";
  rgba = value: alpha: "rgba(${value}${alpha})";
}
