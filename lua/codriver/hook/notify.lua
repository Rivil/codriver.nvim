local M = {}

local last_notified = {}
function M._reset()
  last_notified = {}
end
---@class CodriverRefusal
---@field tool string Name of the tool whose call was blocked
---@field path string Path the call would have written to.

local function one_line(value)
  return (value:gsub("%c", " "))
end

---Announce a refused write in the editor.
---
---Called over RPC by the hook process, so the payload is untrusted data
---from another process rather than something this plugin constructed.
---@param payload CodriverRefusal
---@param now? fun(): integer Monotonic milliseconds. Defaults to vim.uv.now().
function M.refused(payload, now)
  payload = type(payload) == "table" and payload or {}
  local tool = type(payload.tool) == "string" and one_line(payload.tool) or "unknown"
  local path = type(payload.path) == "string" and one_line(payload.path) or "unknown"
  local msg = ("codriver tool %s was blocked on %s"):format(tool, path)
  now = now or vim.uv.now
  local key = tool .. "\0" .. path
  local at = now()
  if last_notified[key] and at - last_notified[key] < 1000 then
    return
  end
  last_notified[key] = at
  vim.notify(msg, vim.log.levels.WARN)
end

return M
