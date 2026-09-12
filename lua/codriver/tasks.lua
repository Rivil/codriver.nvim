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
---@field header string|nil "yours: N  claude: M" tally across the phase's tasks (c-3).
---@field tasks CodriverDrossTask[]|nil Same order as `lines` — the task under the
---cursor at task-line i is `tasks[i]`. Also the list open() passes through to
---ownership.claim/release so a claim/release from the float prunes stale
---entries the same way :CodriverClaim does.

---@return CodriverTasksRender
function M.render()
  local result = require("codriver.dross").read()

  if not result.available then
    return { available = false, reason = result.reason }
  end

  local ownership = require("codriver.ownership")
  local lines = {}
  local human_count, claude_count = 0, 0
  for _, task in ipairs(result.tasks or {}) do
    local owner = ownership.owner(result.phase_id, task.id)
    if owner == ownership.CLAUDE then
      claude_count = claude_count + 1
    else
      human_count = human_count + 1
    end
    table.insert(lines, ("%-6s %-9s %-42s %s"):format(task.id, task.status or "?", task.title or "", owner))
  end

  local header = ("yours: %d  claude: %d"):format(human_count, claude_count)

  return { available = true, phase_id = result.phase_id, lines = lines, header = header, tasks = result.tasks }
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

---@param rendered CodriverTasksRender
---@return string[]
local function build_display(rendered)
  local display = { rendered.header }
  vim.list_extend(display, rendered.lines)
  return display
end

---Open (or notify in place of) the `:CodriverTasks` float. With at least one
---task: `j`/`k` move the cursor between task lines, `c` claims and `r`
---releases the task under the cursor (float_interaction), `d` marks it done
---and `u` reverts it to in_progress (task_status_sync's locked
---trigger_surface/status_range decisions) — all four re-render in place via a
---fresh `M.render()` (so they see any on-disk change the same as a brand new
---open would) and keep the float open. `d`/`u` never mutate a local status
---field directly: the post-attempt render always reflects whatever
---`codriver.task_status.set()`'s write actually left on disk, so a failed
---write structurally cannot leave a stale status on screen. A failed `d`/`u`
---write also `vim.notify`s at ERROR with the failure message. Any other key
---closes, same as every key did before `c`/`r`/`d`/`u` existed. With no tasks
---at all there is nothing to move onto or act on, so it stays the original
---single-keypress close.
function M.open()
  local rendered = M.render()

  if not rendered.available then
    vim.notify(unavailable_message(rendered), vim.log.levels.WARN)
    return
  end

  local tasks = rendered.tasks or {}
  if #tasks == 0 then
    local _, win = M._show({ rendered.header, ("codriver: %s has no tasks yet"):format(rendered.phase_id) })
    vim.cmd("redraw")
    pcall(vim.fn.getchar)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    return
  end

  local buf, win = M._show(build_display(rendered))
  local cursor = 1

  ---Row 1 is the header; task i lives at row i+1.
  local function move_cursor()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { cursor + 1, 0 })
    end
  end

  local function redraw()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_display(rendered))
      vim.bo[buf].modifiable = false
    end
    move_cursor()
    vim.cmd("redraw")
  end

  move_cursor()
  vim.cmd("redraw")

  while true do
    local ok, key = pcall(vim.fn.getchar)
    if not ok then
      break
    end

    local char = type(key) == "number" and vim.fn.nr2char(key) or key

    if char == "j" then
      cursor = math.min(cursor + 1, #tasks)
      move_cursor()
      vim.cmd("redraw")
    elseif char == "k" then
      cursor = math.max(cursor - 1, 1)
      move_cursor()
      vim.cmd("redraw")
    elseif char == "c" or char == "r" then
      local ownership = require("codriver.ownership")
      local task_id = tasks[cursor].id
      if char == "c" then
        ownership.claim(rendered.phase_id, task_id, tasks)
      else
        ownership.release(rendered.phase_id, task_id, tasks)
      end

      rendered = M.render()
      tasks = rendered.tasks or {}
      cursor = math.min(cursor, math.max(#tasks, 1))
      redraw()
    elseif char == "d" or char == "u" then
      local task_status = require("codriver.task_status")
      local task_id = tasks[cursor].id
      local status = char == "d" and "done" or "in_progress"
      local result = task_status.set(rendered.phase_id, task_id, status)
      if not result.ok then
        vim.notify(result.message, vim.log.levels.ERROR)
      end

      rendered = M.render()
      tasks = rendered.tasks or {}
      cursor = math.min(cursor, math.max(#tasks, 1))
      redraw()
    else
      break
    end
  end

  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

return M
