---@brief codriver.nvim — Claude Code as a navigator, not an author.
---
--- This is the wrapper layer. The Claude Code IDE protocol (WebSocket server,
--- lockfile, MCP tools) is vendored from coder/claudecode.nvim under
--- `codriver.vendor.claudecode` and is not modified — see VENDOR.md. Codriver
--- behaviour belongs here, never in there.
---
--- Right now the wrapper is deliberately thin: it delegates setup to the
--- vendored plugin and exposes role state. Turn-taking enforcement, ambient
--- review on save, and dross task binding are not implemented yet.

local M = {}

M.version = {
  major = 0,
  minor = 1,
  patch = 0,
}

---@return string
function M.version:string()
  return ("%d.%d.%d"):format(self.major, self.minor, self.patch)
end

M.role = require("codriver.role")

---The vendored claudecode module, loaded lazily so that merely requiring
---codriver does not spin up the protocol layer.
---@return table
local function vendor()
  return require("codriver.vendor.claudecode")
end

---Set up codriver.
---
---Options are passed through to the vendored claudecode setup unchanged;
---codriver-specific keys will be split out here once there are any.
---@param opts table|nil
---@return table module
function M.setup(opts)
  opts = opts or {}
  vendor().setup(opts)
  return M
end

---Version of codriver itself, and of the vendored protocol layer it wraps.
---@return { codriver: string, claudecode: string }
function M.get_version()
  return {
    codriver = M.version:string(),
    claudecode = vendor().get_version().version,
  }
end

return M
