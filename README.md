# codex.nvim

[![CI](https://github.com/mickyyy68/codex.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/mickyyy68/codex.nvim/actions/workflows/ci.yml)

Neovim integration for the Codex CLI with a tidy, multi-session floating terminal UI. Ships sane defaults so you can keep your `init.lua` minimal.

- Multi-session: create, switch, list, and close Codex sessions
- Floating window with optional winbar “tabs” for sessions
- Auto-install Codex CLI via npm/pnpm/yarn/bun/deno/brew (optional)
- Login precheck and guided `codex login` flow
- Visual selection send (`<leader>as`) with bracketed paste and file header
- Built-in terminal convenience in Codex buffers: `<Esc>` exits, `<C-w>` navigates

## Requirements
- Neovim ≥ 0.9
- Codex CLI available on your PATH (auto-install supported)

## Install (lazy.nvim)
```lua
-- local path while developing
{ dir = "~/dev/codex.nvim-local", name = "codex.nvim", main = "codex", lazy = false }

-- or when hosted online
{ "mickyyy68/codex.nvim", main = "codex", lazy = false }
```

Auto-setup runs on load. Optionally override defaults without writing setup code:
```lua
vim.g.codex_config = {
  border = "rounded",
  width = 0.8,
  height = 0.8,
  autoinstall = true,
}
-- or disable auto-setup entirely and call require('codex').setup() yourself
vim.g.codex_disable_auto_setup = true
```

## Default Keymaps
- `<leader>at` Toggle Codex window
- `<leader>aq` Close Codex window
- `<leader>aN` New session
- `<leader>al` List sessions
- `<leader>an` Next session
- `<leader>ap` Previous session
- `<leader>ax` Close current session
- Visual: `<leader>as` Send selection to the latest session under current cwd

When which-key is installed, a `Codex` group is registered automatically on `VeryLazy`.

## Commands
- `:Codex`, `:CodexToggle` — toggle Codex window
- `:CodexNew [title]` — create a new session (optional title)
- `:CodexList` — pick a session from a list
- `:CodexNext`, `:CodexPrev` — cycle sessions
- `:CodexClose [id]` — close a session by id (or current if omitted)

## Statusline
A small helper for lualine and friends:
```lua
-- returns a component spec (function + cond + icon + color)
require('codex').status()
```
It shows `[Codex:N]` when there are running sessions and the window is not visible.

## Configuration
```lua
require('codex').setup({
  keymaps = {
    toggle = '<leader>at',
    quit = '<leader>aq',
    next = '<leader>an',
    prev = '<leader>ap',
    new = '<leader>aN',
    list = '<leader>al',
    close_session = '<leader>ax',
    send_selection = '<leader>as',
  },
  border = 'rounded',     -- string | table (ui.border-like)
  width = 0.8,            -- 0..1 fraction of columns
  height = 0.8,           -- 0..1 fraction of lines
  cmd = 'codex',          -- string or argv table
  model = nil,            -- e.g. 'gpt-5-codex'
  autoinstall = true,     -- prompt to install CLI if missing
  winbar = true,          -- show session tabs in winbar
  max_sessions = 8,
})
```

## Auto-install Notes
If Codex isn’t found, you can pick a package manager. On success but missing PATH, helpful messages guide you to add the correct bin dir for pnpm/yarn/bun/deno. Homebrew installs are typically already on PATH.

## Visual Send Details
`<leader>as` (visual) creates or focuses the latest session for the current cwd, waits until the job is ready, then bracketed-pastes a header like `[file: relative/path.ts]` followed by the selection, without submitting a trailing newline.

## Terminal Convenience
Inside Codex buffers:
- `<Esc>` leaves terminal mode
- `<C-w>` opens window command prefix (after exiting terminal)

No global `TermOpen` autocommand is required.

## License
Licensed under the MIT License. See `LICENSE` for details.
