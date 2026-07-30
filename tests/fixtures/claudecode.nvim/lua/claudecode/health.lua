-- The rival plugin's `:checkhealth claudecode` section.
--
-- Neovim resolves a health check by globbing `lua/**/<name>/health.lua`, on the
-- *directory* name — so this file is the one and only thing that should answer
-- `:checkhealth claudecode`. Codriver's vendored tree also lives in a directory
-- called `claudecode`, which is why scripts/vendor-sync.sh renames its
-- `health.lua` to `health_vendored.lua`. Without that rename, merely installing
-- codriver would inject a second section into this report.

local M = {}

---Read by the check when it asserts which file the glob resolved to.
M.marker = "claudecode.nvim fixture health"

function M.check()
  vim.health.start("claudecode.nvim (fixture)")
  vim.health.ok("this section belongs to the other plugin, not to codriver")
end

return M
