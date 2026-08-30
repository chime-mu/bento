-- bento's Neovim.
--
-- Written as Lua rather than as a Nix string, and read in with `builtins.readFile` from
-- ../neovim.nix. Two reasons: this file is Lua that an editor, a formatter and a language
-- server can all understand, and it contains no `${...}` — nothing here is interpolated
-- from the theme, because tokyonight.nvim *is* the theme, upstream, with the same palette
-- home/chime/theme/colors.nix transcribes for everything else.
--
-- Every plugin is installed by Nix (see ../neovim.nix); nothing is fetched at runtime.
-- So this file only ever calls `setup()`, never a plugin manager.

-- Leader has to be set before anything binds a `<leader>` mapping. init.lua runs before
-- the packages' own plugin scripts, so here is early enough.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- `setup(name, opts)` instead of a bare `require(name).setup(opts)`.
--
-- A plugin that has been renamed, dropped from nixpkgs, or has moved its setup entry
-- point is a real possibility on nixos-unstable, and the bare form turns any one of those
-- into an editor that does not start — from which the config that caused it cannot be
-- edited. This turns it into one message and a working nvim.
local function setup(name, opts)
  local ok, mod = pcall(require, name)
  if not ok then
    vim.notify("bento: plugin not found: " .. name, vim.log.levels.WARN)
    return
  end
  local configured, err = pcall(mod.setup, opts or {})
  if not configured then
    vim.notify("bento: " .. name .. ".setup() failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

-- ---------------------------------------------------------------- options

local o = vim.opt

o.number = true
o.relativenumber = true
o.cursorline = true
o.signcolumn = "yes" -- never let the gutter appear and shift the text sideways
o.scrolloff = 4
o.wrap = false

o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.smartindent = true

o.ignorecase = true
o.smartcase = true
o.inccommand = "split" -- live preview of :s

o.splitright = true
o.splitbelow = true

o.undofile = true -- undo survives closing the file; this is a VM that gets rebuilt a lot
o.swapfile = false
o.updatetime = 250

o.termguicolors = true
o.mouse = "a"
o.confirm = true -- ask rather than refuse when quitting with unsaved changes

-- wl-clipboard is in modules/desktop.nix, so yanking reaches the Wayland selection and
-- Ghostty. Over ssh, with no WAYLAND_DISPLAY, neovim simply finds no provider and the
-- unnamed register keeps working — it degrades rather than failing.
o.clipboard = "unnamedplus"

vim.diagnostic.config({
  virtual_text = { prefix = "●" },
  severity_sort = true,
  float = { border = "rounded" },
})

-- ---------------------------------------------------------------- colours

setup("tokyonight", {
  style = "night",
  -- The terminal underneath is already Tokyo Night (home/chime/ghostty.nix), so a
  -- transparent background would be the same colour with worse contrast on the parts
  -- neovim does not paint.
  transparent = false,
  styles = { comments = { italic = true } },
})
pcall(vim.cmd.colorscheme, "tokyonight-night")

-- ---------------------------------------------------------------- plugins

setup("which-key", { preset = "helix" })

-- Treesitter highlighting.
--
-- **There is no `require("nvim-treesitter.configs").setup{ highlight = { enable = true } }`
-- here**, which is what every guide, and nvim-treesitter's own pre-2025 README, tells you
-- to write. nixpkgs ships the plugin's **`main`** branch, where that module does not
-- exist at all: `lua/nvim-treesitter/` contains only init, config, install, parsers,
-- indent and health, and `setup()` now configures where `:TSInstall` *downloads* to —
-- which on a machine whose parsers are a read-only store path is not a question.
--
-- Highlighting moved to Neovim itself. `vim.treesitter.start()` is the whole feature, and
-- `withAllGrammars` puts both halves it needs on the runtimepath:
--
--   .../pack/hm/start/nvim-treesitter-grammars/parser/nix.so
--   .../pack/hm/start/nvim-treesitter-grammars/queries/nix/highlights.scm
--
-- `pcall`, because a filetype with no parser is normal, not an error — `start()` throws
-- for those, and an uncaught throw inside a FileType autocmd is an error message on every
-- single buffer of that type.
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("bento_treesitter", { clear = true }),
  callback = function(ev)
    pcall(vim.treesitter.start, ev.buf)
  end,
})

setup("gitsigns")
setup("nvim-web-devicons")
setup("bufferline")
setup("ibl", { indent = { char = "│" } })
setup("flash")

setup("lualine", {
  options = {
    theme = "tokyonight",
    globalstatus = true,
    section_separators = "",
    component_separators = "|",
  },
})

setup("neo-tree", {
  close_if_last_window = true,
  filesystem = {
    follow_current_file = { enabled = true },
    -- The bento repo has no dotfile-heavy layout, but ~/.config does, and this editor is
    -- pointed at both.
    filtered_items = { visible = true, hide_dotfiles = false, hide_gitignored = true },
  },
})

setup("telescope", {
  defaults = {
    prompt_prefix = "  ",
    selection_caret = "  ",
    path_display = { "truncate" },
  },
})
pcall(function()
  require("telescope").load_extension("fzf")
end)

-- mini.nvim ships as one plugin and many modules; each is required separately.
setup("mini.ai") -- `ci(`, `da"`, and friends, with treesitter-aware textobjects
setup("mini.pairs")
setup("mini.surround")

setup("conform", {
  formatters_by_ft = {
    -- nixfmt-rfc-style is in ../neovim.nix's extraPackages. This is the formatter the
    -- rest of this repo is written to.
    nix = { "nixfmt" },
    lua = { "stylua" },
  },
  format_on_save = { timeout_ms = 2000, lsp_format = "fallback" },
})

setup("blink.cmp", {
  keymap = { preset = "default" },
  appearance = { nerd_font_variant = "mono" },
  sources = { default = { "lsp", "path", "buffer" } },
  completion = { documentation = { auto_show = true, auto_show_delay_ms = 200 } },
})

-- ---------------------------------------------------------------- lsp
--
-- Neovim 0.11 moved server definitions onto the runtimepath: `vim.lsp.enable("nil_ls")`
-- looks for `lsp/nil_ls.lua`, which is what nvim-lspconfig now ships. So there is no
-- `require("lspconfig").nil_ls.setup{}` here — that is the pre-0.11 spelling, and every
-- guide still uses it.
vim.lsp.config("lua_ls", {
  settings = {
    Lua = {
      -- Without this, every `vim` in this very file is an undefined global.
      diagnostics = { globals = { "vim" } },
      workspace = { checkThirdParty = false },
      telemetry = { enable = false },
    },
  },
})

pcall(vim.lsp.enable, { "nil_ls", "lua_ls" })

-- ---------------------------------------------------------------- keymaps
--
-- LazyVim's scheme, as far as there is a plugin behind each one: `<leader>f` finds,
-- `<leader>g` is git, `<leader>b` is buffers, `<leader>c` is code.

local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
end

map("n", "<leader>w", "<cmd>write<cr>", "Save file")
map("n", "<leader>q", "<cmd>quit<cr>", "Quit window")
map("n", "<esc>", "<cmd>nohlsearch<cr>", "Clear search highlight")

map("n", "<leader>e", "<cmd>Neotree toggle<cr>", "Explorer")

map("n", "<leader>ff", "<cmd>Telescope find_files<cr>", "Find files")
map("n", "<leader>fg", "<cmd>Telescope live_grep<cr>", "Grep")
map("n", "<leader>fb", "<cmd>Telescope buffers<cr>", "Buffers")
map("n", "<leader>fh", "<cmd>Telescope help_tags<cr>", "Help")
map("n", "<leader>fd", "<cmd>Telescope diagnostics<cr>", "Diagnostics")

map("n", "<leader>bd", "<cmd>bdelete<cr>", "Delete buffer")
map("n", "<S-h>", "<cmd>bprevious<cr>", "Previous buffer")
map("n", "<S-l>", "<cmd>bnext<cr>", "Next buffer")

map("n", "<C-h>", "<C-w>h", "Window left")
map("n", "<C-j>", "<C-w>j", "Window down")
map("n", "<C-k>", "<C-w>k", "Window up")
map("n", "<C-l>", "<C-w>l", "Window right")

map("n", "grn", vim.lsp.buf.rename, "Rename symbol")
map("n", "<leader>ca", vim.lsp.buf.code_action, "Code action")
map("n", "<leader>cf", function()
  require("conform").format({ lsp_format = "fallback" })
end, "Format buffer")

map({ "n", "x", "o" }, "s", function()
  require("flash").jump()
end, "Flash jump")

-- Yank highlight: the only way to see that a motion did what you meant without checking
-- the register afterwards.
vim.api.nvim_create_autocmd("TextYankPost", {
  group = vim.api.nvim_create_augroup("bento_yank", { clear = true }),
  callback = function()
    vim.hl.on_yank({ timeout = 150 })
  end,
})
