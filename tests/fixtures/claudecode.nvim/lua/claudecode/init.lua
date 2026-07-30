-- Stand-in for a real coder/claudecode.nvim install, used by
-- tests/nvim/coexistence_check.lua.
--
-- Deliberately a fake rather than a checkout of upstream. Every way codriver
-- could break a user who has both plugins installed is a *name* collision — the
-- `claudecode` module namespace, the `:ClaudeCode*` commands, the
-- `ClaudeCodeShutdown` augroup, and `lua/**/claudecode/health.lua`. So the
-- fixture claims exactly those names and nothing else, and each one carries a
-- marker the check can read back. A real upstream checkout would add hundreds
-- of files and a second WebSocket server without testing anything more.

local M = {}

---Read by the check to prove `require("claudecode")` resolved here and not to
---codriver's vendored copy.
M.marker = "claudecode.nvim fixture"

---Bumped by the fixture's own command handlers. `:ClaudeCodeStart` running the
---fixture's handler — rather than codriver's, or nothing at all — is the whole
---question.
---@type table<string, integer>
M.invoked = {}

---@param name string
function M.record(name)
  M.invoked[name] = (M.invoked[name] or 0) + 1
end

return M
