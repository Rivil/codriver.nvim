-- Load guard only. Commands are registered by require("codriver").setup().
--
-- Note the version floor differs from vendored claudecode.nvim's (0.8.0):
-- codriver targets the Neovim pinned in mise.toml and does not test older.

if vim.fn.has("nvim-0.11.0") ~= 1 then
  vim.api.nvim_echo({ { "codriver.nvim requires Neovim >= 0.11.0", "ErrorMsg" } }, true, {})
  return
end

if vim.g.loaded_codriver then
  return
end
vim.g.loaded_codriver = 1
