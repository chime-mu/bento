# Fonts. Omarchy's choice — CaskaydiaMono Nerd Font — plus enough coverage that nothing
# on the screen falls back to a box.
#
# Until this file existed the guest ran on `fonts.enableDefaultPackages`, which
# `programs.hyprland` turns on transitively through `services.graphical-desktop`
# (learned/phase-3.md §3). That is why `foot` had something to render with in Phase 3. It
# is *kept* on below rather than replaced: it is what supplies DejaVu and the fontconfig
# defaults that random GTK dialogs reach for, and the Nerd Font is an addition to that
# baseline, not a substitute for it.
{ pkgs, ... }:
{
  fonts = {
    enableDefaultPackages = true;

    packages = with pkgs; [
      # The whole point. In nixpkgs the nerd-fonts have been split out of the old
      # `nerdfonts` mega-package into `nerd-fonts.<name>` — one derivation per family,
      # 52 MiB instead of 4 GiB. `nerd-fonts.caskaydia-mono` is Cascadia Mono patched with
      # the Nerd Font glyph sets, which is what the bar's icons come from.
      nerd-fonts.caskaydia-mono

      # Metric-compatible stand-ins for Arial/Times/Courier, so a web page or a document
      # that asks for those by name gets the right *shapes* rather than a substitute at
      # the wrong width.
      liberation_ttf

      # The coverage net: Noto is the family whose whole purpose is having a glyph.
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-emoji
    ];

    # fontconfig resolves the generic families through these lists in order. Naming the
    # Nerd Font first for monospace is what makes  glyphs work in every terminal and in
    # waybar without each of them configuring it separately.
    #
    # Monospace gets the non-`Mono` variant deliberately: the "Mono" patch squeezes every
    # icon into a single cell and clips the wide ones. See the note in home/chime/theme.
    fontconfig.defaultFonts = {
      monospace = [
        "CaskaydiaMono Nerd Font"
        "Noto Sans Mono"
      ];
      sansSerif = [
        "Liberation Sans"
        "Noto Sans"
      ];
      serif = [
        "Liberation Serif"
        "Noto Serif"
      ];
      emoji = [ "Noto Color Emoji" ];
    };
  };
}
