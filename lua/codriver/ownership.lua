---@brief Codriver-local task-ownership mapping (human vs Claude).
---
--- Per phase-binding's locked `ownership_source` decision: task ownership is
--- not a dross schema field and not inferred by heuristic — it is an
--- explicit, codriver-local `(phase_id, task_id) -> owner` mapping, set only
--- by `:CodriverClaim`. Keyed by phase id *and* task id together, nested as
--- `{[phase_id] = {[task_id] = "claude"}}`, so a task id claimed in one phase
--- never bleeds into another phase reusing the same id.
---
--- Stored at `.dross/.codriver-ownership.json`, gitignored: this is a
--- statement about who is doing what on this machine right now, not
--- something to commit or share.

local M = {}

local RELATIVE_PATH = ".dross/.codriver-ownership.json"

M.HUMAN = "human"
M.CLAUDE = "claude"

---@return string
local function store_path()
  return vim.fn.getcwd() .. "/" .. RELATIVE_PATH
end

---@return table<string, table<string, string>>
local function load()
  local path = store_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

---@param store table
local function save(store)
  local path = store_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(store) }, path)
end

---Claim a task as Claude's, for a specific phase.
---@param phase_id string
---@param task_id string
function M.claim(phase_id, task_id)
  local store = load()
  store[phase_id] = store[phase_id] or {}
  store[phase_id][task_id] = M.CLAUDE
  save(store)
end

---Who owns a task. Unclaimed, or a phase/task id never seen, defaults to the
---human — ownership is opt-in, never assumed.
---@param phase_id string
---@param task_id string
---@return string
function M.owner(phase_id, task_id)
  local phase = load()[phase_id]
  if not phase then
    return M.HUMAN
  end
  return phase[task_id] or M.HUMAN
end

---Whether `task_id` appears in a `codriver.dross`.read() task list. A tiny
---pure helper so `:CodriverClaim`'s "is this a real task" WARN is testable
---with no vim.* stub at all — just the list.
---@param task_id string
---@param tasks CodriverDrossTask[]|nil
---@return boolean
function M.is_known(task_id, tasks)
  for _, task in ipairs(tasks or {}) do
    if task.id == task_id then
      return true
    end
  end
  return false
end

return M
