# Neovim — the editor, and the one an agent's `$EDITOR` lands in.
#
# ## The substitution: "LazyVim-style", not LazyVim
#
# PLAN-v1 §5 step 3 says *"LazyVim-style via home-manager (`programs.neovim` + LazyVim
# config files; don't over-engineer with nixvim in v1)"*. This is the style, declaratively:
# LazyVim's plugin set, LazyVim's keymap scheme, and LazyVim's own default colorscheme
# (tokyonight — the same theme the rest of this desktop wears), with every plugin coming
# from nixpkgs.
#
# LazyVim itself is not installed, and that is deliberate rather than a shortcut:
#
#   1. **It is a plugin manager at runtime.** LazyVim is a lazy.nvim configuration, and
#      lazy.nvim's job is to `git clone` fifty repositories into ~/.local/share/nvim on
#      first launch. On a machine whose defining property is that its software list is a
#      flake, that is the one component that would not be. It also makes "does the editor
#      work?" a question about GitHub's availability, which is a poor thing to discover
#      during a phase acceptance test.
#   2. **It wants to own ~/.config/nvim**, which home-manager is writing read-only store
#      symlinks into. The two are not merely redundant, they collide.
#   3. **PLAN-v1 risk #2 forbids source builds in the VM.** Every plugin below was probed
#      with `nix build --dry-run`; those that report "will be built" are `buildVimPlugin`
#      derivations — an unpack and a copy of an already-fetched source, seconds each — not
#      compiles. Nothing here is a `nodejs`-shaped surprise.
#
# The genuine loss is LazyVim's `:LazyExtras` menu and its per-language presets. Adding a
# plugin here is a line in the list below plus a `setup()` call in ./neovim/init.lua, which
# for a v1 desktop is the right size of ceremony.
{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;

    # `EDITOR`/`VISUAL`. This matters more here than on a normal desktop: it is what
    # `git commit`, `systemctl edit` and Claude Code's own editor hand-off all resolve to
    # inside the VM.
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    extraLuaConfig = builtins.readFile ./neovim/init.lua;

    # Runtime dependencies of the config above, kept next to the thing that needs them.
    extraPackages = with pkgs; [
      # LSP servers, reached through `vim.lsp.enable` in init.lua. `nil` is the one that
      # matters on this machine — the file being edited is almost always a .nix file that
      # is about to become the operating system.
      nil
      lua-language-server

      # conform's formatter for Nix. `nixfmt-rfc-style` is the RFC 166 formatter, which is
      # what nixpkgs itself and this repo are written to; the older `nixfmt` package is a
      # different layout.
      nixfmt-rfc-style

      # telescope shells out to both: `live_grep` is ripgrep and `find_files` prefers fd.
      # They are also in modules/agent.nix — listing them again here is what keeps this
      # module honest if it is ever imported on a machine without the agent.
      ripgrep
      fd
    ];

    plugins = with pkgs.vimPlugins; [
      # LazyVim's default colorscheme, and the upstream source of the palette that
      # home/chime/theme/colors.nix transcribes for waybar, walker, mako and the terminals.
      tokyonight-nvim

      # `withAllGrammars` rather than a hand-picked list: the parsers are ~40 MiB of
      # already-cached store paths, and the alternative is discovering a missing grammar
      # the first time a file of that type is opened. Neovim 0.12 ships treesitter itself,
      # but not the parsers.
      nvim-treesitter.withAllGrammars

      plenary-nvim # telescope's dependency, not used directly
      telescope-nvim
      telescope-fzf-native-nvim # the C sorter; without it telescope's matching is Lua

      nvim-lspconfig
      blink-cmp # completion. LazyVim's choice since v14, replacing nvim-cmp
      conform-nvim # formatting

      lualine-nvim
      bufferline-nvim
      which-key-nvim
      indent-blankline-nvim
      gitsigns-nvim
      flash-nvim

      neo-tree-nvim
      nui-nvim # neo-tree's dependency
      nvim-web-devicons # and the reason modules/fonts.nix has a Nerd Font

      mini-nvim # ai / pairs / surround, set up individually in init.lua
    ];
  };
}
