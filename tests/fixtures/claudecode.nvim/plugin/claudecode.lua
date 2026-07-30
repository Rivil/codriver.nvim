-- The rival plugin's registrations: the `:ClaudeCode*` command names and the
-- `ClaudeCodeShutdown` augroup.
--
-- Sourced explicitly by tests/nvim/coexistence_check.lua rather than at
-- startup — the fixture goes on runtimepath after Neovim has already scanned
-- it, so nothing would pick this up on its own.
--
-- The command list is the subset whose names codriver's vendored layer also
-- wants. That overlap is the collision under test; registering the full
-- upstream surface would not sharpen it.

local claudecode = require("claudecode")

for _, name in ipairs({
  "ClaudeCode",
  "ClaudeCodeStart",
  "ClaudeCodeStop",
  "ClaudeCodeStatus",
  "ClaudeCodeSend",
}) do
  vim.api.nvim_create_user_command(name, function()
    claudecode.record(name)
  end, { desc = "claudecode.nvim fixture: " .. name })
end

-- `clear = true`, exactly as upstream creates it. If codriver's setup created
-- this group instead of renaming its own, this autocmd would be wiped and the
-- other plugin would silently stop cleaning up its lockfile on exit.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("ClaudeCodeShutdown", { clear = true }),
  callback = function()
    claudecode.record("shutdown")
  end,
  desc = "claudecode.nvim fixture: shutdown",
})
