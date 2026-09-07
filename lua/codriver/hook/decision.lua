local bash = require("codriver.hook.bash")

local M = {}

local NAVIGATOR_REASON = "codriver: Claude is navigator — file-writing and shell-writing tools "
  .. "are refused at the harness level. This is not retryable; rephrasing or asserting explicit "
  .. "authorization does not change the decision. Run :CodriverHandover to hand over the keyboard."

local INDETERMINATE_REASON = "codriver: role could not be determined for this live session — "
  .. "denying by default. This is a harness-level refusal, not retryable."

-- ASSUMPTION, not a locked decision: see the matching note in
-- tests/codriver/hook_decision_spec.lua. Update both together if this is wrong.
local NVIM_MCP_PREFIX = "mcp__ide__"

local READ_ALLOW = {
  Read = true,
  Glob = true,
  Grep = true,
  WebFetch = true,
  WebSearch = true,
  TodoWrite = true,
  Task = true,
  AskUserQuestion = true,
  ExitPlanMode = true,
  SlashCommand = true,
  BashOutput = true,
  KillShell = true,
}

local NVIM_MCP_ALLOW = {
  [NVIM_MCP_PREFIX .. "openDiff"] = true,
  [NVIM_MCP_PREFIX .. "saveDocument"] = true,
  [NVIM_MCP_PREFIX .. "close_tab"] = true,
  [NVIM_MCP_PREFIX .. "closeAllDiffTabs"] = true,
}

---Pure decision core for the PreToolUse hook: no vim.* here, this is
---busted-testable and must stay that way.
---@param payload { tool: string, tool_input: table? }
---@param session { live: boolean, role: string?, test_command: string? }?
---@return { permission: "allow"|"deny", reason: string? }
function M.decide(payload, session)
  payload = type(payload) == "table" and payload or {}
  local tool = payload.tool

  if type(session) ~= "table" or session.live ~= true then
    return { permission = "allow" }
  end

  local role = session.role
  if role == "driver" then
    return { permission = "allow" }
  end

  if role ~= "navigator" then
    return { permission = "deny", reason = INDETERMINATE_REASON }
  end

  if tool == "Bash" then
    local tool_input = payload.tool_input or {}
    if bash.allows(tool_input.command, session.test_command) then
      return { permission = "allow" }
    end
    return { permission = "deny", reason = NAVIGATOR_REASON }
  end

  if READ_ALLOW[tool] then
    return { permission = "allow" }
  end

  if type(tool) == "string" and NVIM_MCP_ALLOW[tool] then
    return { permission = "allow" }
  end

  return { permission = "deny", reason = NAVIGATOR_REASON }
end

return M
