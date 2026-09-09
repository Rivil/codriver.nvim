---@brief Reads dross phase + task state directly off disk.
---
--- Per phase-binding's locked `dross_dependency` decision: no runtime
--- dependency on the `dross` binary being on PATH. `.dross/state.json` and the
--- active phase's `plan.toml`, both relative to `vim.fn.getcwd()`, are read
--- directly instead.
---
--- No TOML library exists in this repo, so plan.toml parsing is a narrow
--- field-extractor scoped to exactly what the task surface needs: it pulls
--- id/title/status out of each `[[task]]` block and ignores every other field
--- (files, description, covers, test_contract, depends_on, wave).
---
--- Every failure mode — missing `.dross/`, missing/corrupt state.json, no
--- active phase, or a malformed plan.toml — returns a structured
--- `{available = false}` result instead of raising, so a caller never needs a
--- pcall around this (c-5).

local M = {}

---@class CodriverDrossTask
---@field id string
---@field title string|nil
---@field status string|nil

---@class CodriverDrossResult
---@field available boolean
---@field reason string|nil Set to "corrupt" when a file existed but failed to parse.
---@field phase_id string|nil
---@field tasks CodriverDrossTask[]|nil

---Extract id/title/status out of each `[[task]]` block. A block with no `id`
---is treated as corrupt: t-2's ownership mapping is keyed on task id, and a
---task with no id is not one the rest of this phase can do anything with.
---@param text string
---@return CodriverDrossTask[]|nil, string|nil
local function parse_tasks(text)
  local tasks = {}
  local current = nil

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")

    if trimmed == "[[task]]" then
      if current then
        table.insert(tasks, current)
      end
      current = {}
    elseif trimmed:match("^%[") then
      -- Any other table header ([phase], [[criteria]], ...) closes whatever
      -- [[task]] block was open.
      if current then
        table.insert(tasks, current)
        current = nil
      end
    elseif current then
      local key, value = trimmed:match('^(%a+)%s*=%s*"(.-)"$')
      if key == "id" or key == "title" or key == "status" then
        current[key] = value
      end
    end
  end
  if current then
    table.insert(tasks, current)
  end

  for _, task in ipairs(tasks) do
    if not task.id then
      return nil, "corrupt"
    end
  end

  return tasks
end

---Read the active dross phase and its task list.
---@return CodriverDrossResult
function M.read()
  local root = vim.fn.getcwd()
  local state_path = root .. "/.dross/state.json"

  if vim.fn.filereadable(state_path) ~= 1 then
    return { available = false }
  end

  local ok, state = pcall(vim.json.decode, table.concat(vim.fn.readfile(state_path), "\n"))
  if not ok or type(state) ~= "table" then
    return { available = false, reason = "corrupt" }
  end

  local phase_id = state.current_phase
  if type(phase_id) ~= "string" or phase_id == "" then
    return { available = false }
  end

  local plan_path = ("%s/.dross/phases/%s/plan.toml"):format(root, phase_id)
  if vim.fn.filereadable(plan_path) ~= 1 then
    -- A phase can be current before it has a plan (spec-only) — untracked
    -- is a stronger claim than "no tasks yet", so this is still available.
    return { available = true, phase_id = phase_id, tasks = {} }
  end

  local tasks, err = parse_tasks(table.concat(vim.fn.readfile(plan_path), "\n"))
  if not tasks then
    return { available = false, reason = err }
  end

  return { available = true, phase_id = phase_id, tasks = tasks }
end

return M
