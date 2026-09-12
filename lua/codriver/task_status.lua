---@brief Writes a task's dross status through to plan.toml via the `dross` CLI.
---
--- Per task-status-sync's locked `write_mechanism` decision: plan.toml has no
--- writer in this repo, so a status change shells out to `dross task status
--- <phase_id> <task_id> <status>` rather than hand-rolling one.
---
--- `vim.system()` raises synchronously — before `:wait()` ever runs — when the
--- executable can't be spawned (e.g. `dross` not on PATH), so the spawn call
--- itself is wrapped in `pcall`, not just `:wait()`'s result, or a missing
--- binary would error instead of degrading to `{ok = false}`.

local M = {}

---@class CodriverTaskStatusResult
---@field ok boolean
---@field message string|nil Set when `ok` is false: the command's stderr
---(falling back to stdout), or the pcall error string on a spawn failure.

---Shell out to `dross task status <phase_id> <task_id> <status>`.
---@param phase_id string
---@param task_id string
---@param status string
---@return CodriverTaskStatusResult
function M.set(phase_id, task_id, status)
  local spawned, handle_or_err = pcall(vim.system, { "dross", "task", "status", phase_id, task_id, status }, { text = true })
  if not spawned then
    return { ok = false, message = tostring(handle_or_err) }
  end

  local result = handle_or_err:wait()
  if result.code == 0 then
    return { ok = true }
  end

  local message = result.stderr
  if not message or message == "" then
    message = result.stdout
  end
  return { ok = false, message = message }
end

return M
