-- Auto-setup for codex.nvim
-- This file runs when the plugin is on 'runtimepath'.
-- It calls require('codex').setup() with either defaults or a user-provided
-- table in `vim.g.codex_config`. To disable auto-setup, set
--   vim.g.codex_disable_auto_setup = true

local ok, codex = pcall(require, 'codex')
if not ok then
  return
end

local disable = vim.g.codex_disable_auto_setup
if disable == true or disable == 1 or disable == '1' then
  return
end

local cfg = vim.g.codex_config
-- `codex` is callable via its metatable; this invokes setup(cfg)
pcall(codex, cfg)

