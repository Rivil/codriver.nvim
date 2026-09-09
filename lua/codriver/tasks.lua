---@brief `:CodriverTasks` — a read-only view of the current dross phase's tasks.
---
--- `render()` re-reads `codriver.dross` and `codriver.ownership` fresh on
--- every call (c-4): nothing here is cached from a previous open, so an
--- on-disk `plan.toml` edit between two `:CodriverTasks` shows up on the next
--- one. When there is nothing to show — no active phase, or a corrupt
--- `plan.toml` — `open()` notifies instead of opening a buffer or erroring
--- (c-5).
---
--- `dross`/`ownership` are required at call time, not at module load, so a
--- busted spec can swap `package.loaded` with a fake before calling
--- `render()` — the same reason `codriver.session` requires the vendored
--- layer lazily.

local M = {}

---@class CodriverTasksRender
---@field available boolean
---@field reason string|nil Set to "corrupt" when a file existed but failed to parse.
---@field phase_id string|nil
---@field lines string[]|nil One line per task: "id  status  title  (owner)".

---@return CodriverTasksRender
function M.render()
  local result = require("codriver.dross").read()

  if not result.available then
    return { available = false, reason = result.reason }
  end

  local ownership = require("codriver.ownership")
  local lines = {}
  for _, task in ipairs(result.tasks or {}) do
    local owner = ownership.owner(result.phase_id, task.id)
    table.insert(lines, ("%-6s %-9s %-42s %s"):format(task.id, task.status or "?", task.title or "", owner))
  end

  return { available = true, phase_id = result.phase_id, lines = lines }
end

---@param rendered CodriverTasksRender
---@return string
local function unavailable_message(rendered)
  if rendered.reason == "corrupt" then
    return "codriver: the current phase's plan.toml is corrupt — nothing to show"
  end
  return "codriver: no active dross phase — nothing to show"
end

---Create the read-only scratch buffer + centered float for `lines`. Split out
---from `open()` so a headless check can inspect its content without also
---waiting through `open()`'s blocking close-on-any-key.
---@param lines string[]
---@return integer buf
---@return integer win
function M._show(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, #line + 2)
  end
  width = math.min(width, math.max(vim.o.columns - 4, 20))
  local height = math.min(math.max(#lines, 1), math.max(vim.o.lines - 4, 1))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " codriver tasks ",
  })

  return buf, win
end

---Open (or notify in place of) the read-only `:CodriverTasks` float. Closes
---on any keypress.
function M.open()
  local rendered = M.render()

  if not rendered.available then
    vim.notify(unavailable_message(rendered), vim.log.levels.WARN)
    return
  end

  local lines = rendered.lines
  if #lines == 0 then
    lines = { ("codriver: %s has no tasks yet"):format(rendered.phase_id) }
  end

  local _, win = M._show(lines)

  vim.cmd("redraw")
  -- Blocks for exactly one keypress, whatever it is — this is a read-only
  -- view with nothing to bind individual keys to.
  pcall(vim.fn.getchar)

  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

return M
