-- :CodriverTasks — real buffer/float and close-on-any-key — run under real
-- Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/tasks_check.lua
--
-- tasks_spec.lua already proves render()'s re-read/formatting logic against
-- fakes; this file is only for the claims that need a real vim.api window
-- and a real keypress to mean anything.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

-- Moved before anything runs: dross.read() reads vim.fn.getcwd() directly,
-- and this must never see the repo root's own real, tracked `.dross/`.
local PROJECT = harness.sandbox_root .. "/project"
vim.fn.mkdir(PROJECT, "p")
vim.fn.chdir(PROJECT)

local ownership = require("codriver.ownership")
local tasks = require("codriver.tasks")

---@return table<integer, true>
local function win_set()
  local set = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    set[w] = true
  end
  return set
end

---@return { msg: string, level: integer }[]
local function capture_notifications(fn)
  local notifications = {}
  local real_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end
  fn()
  vim.notify = real_notify
  return notifications
end

-- 1. No .dross/ at all: notifies, opens no window.
local before = win_set()
local no_phase_notifications = capture_notifications(function()
  tasks.open()
end)
local after = win_set()

harness.expect_eq(vim.tbl_count(after), vim.tbl_count(before), "no active phase must not leave a window open")
harness.expect(#no_phase_notifications >= 1, "expected a notification when there is no active phase")
harness.expect_eq(
  no_phase_notifications[1].level,
  vim.log.levels.WARN,
  "the no-active-phase notification must be a WARN"
)

-- 2. A corrupt plan.toml: same — notifies, opens no window, does not error.
harness.write(PROJECT .. "/.dross/state.json", vim.json.encode({ current_phase = "phase-x" }))
harness.write(
  PROJECT .. "/.dross/phases/phase-x/plan.toml",
  table.concat({
    "[phase]",
    'id = "phase-x"',
    "",
    "[[task]]",
    'title = "no id on this one"',
  }, "\n")
)

before = win_set()
local corrupt_ok, corrupt_notifications = pcall(function()
  return capture_notifications(function()
    tasks.open()
  end)
end)
after = win_set()

harness.expect(corrupt_ok, "open() must not raise on a corrupt plan.toml")
harness.expect_eq(vim.tbl_count(after), vim.tbl_count(before), "a corrupt plan.toml must not leave a window open")
harness.expect(#corrupt_notifications >= 1, "expected a notification for a corrupt plan.toml")

-- 3. A valid plan.toml with a claimed task: render() + _show() end to end
-- shows id, title, status, and owner.
harness.write(
  PROJECT .. "/.dross/phases/phase-x/plan.toml",
  table.concat({
    "[phase]",
    'id = "phase-x"',
    "",
    "[[task]]",
    'id            = "t-1"',
    'title         = "First task"',
    'status        = "pending"',
    "",
    "[[task]]",
    'id            = "t-2"',
    'title         = "Second task"',
    'status        = "done"',
  }, "\n")
)
ownership.claim("phase-x", "t-1")

local rendered = tasks.render()
harness.expect(rendered.available, "expected a valid plan.toml to render as available")
harness.expect_eq(#rendered.lines, 2, "expected one line per task")

local buf, win = tasks._show(rendered.lines)
local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

harness.expect_contains(buf_lines[1], "t-1", "first task line: id")
harness.expect_contains(buf_lines[1], "First task", "first task line: title")
harness.expect_contains(buf_lines[1], "pending", "first task line: status")
harness.expect_contains(buf_lines[1], "claude", "first task line: claimed owner")
harness.expect_contains(buf_lines[2], "human", "second task line: unclaimed owner defaults to human")
harness.expect_eq(vim.bo[buf].modifiable, false, "the tasks buffer must be read-only")

vim.api.nvim_win_close(win, true)

-- 4. Pressing any key closes the real open() float — a window is actually
-- created (WinEnter fires), and gone again by the time open() returns.
local win_enters = 0
local group = vim.api.nvim_create_augroup("TasksCheckWinEnter", { clear = true })
vim.api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    win_enters = win_enters + 1
  end,
})

before = win_set()
vim.api.nvim_feedkeys("q", "nt", false)
tasks.open()
after = win_set()

vim.api.nvim_del_augroup_by_id(group)

harness.expect(win_enters >= 1, "expected open() to actually open a window before closing it")
harness.expect_eq(vim.tbl_count(after), vim.tbl_count(before), "expected the window to be closed after a keypress")

-- 5. `c` claims the task under the cursor and `r` releases it — moved there
-- with `j` first — without the float closing before the trailing `q`.
-- getchar(1) peeks the input queue without consuming it, so a leftover
-- keystroke here would mean the loop exited (and closed the float) early.
harness.expect_eq(ownership.owner("phase-x", "t-2"), ownership.HUMAN, "t-2 starts unclaimed")

vim.api.nvim_feedkeys("jcq", "nt", false)
tasks.open()

harness.expect_eq(ownership.owner("phase-x", "t-2"), ownership.CLAUDE, "`c` on the cursor task must claim it")
harness.expect_eq(vim.fn.getchar(1), 0, "`j` then `c` must not close the float before the trailing `q` is read")

vim.api.nvim_feedkeys("jrq", "nt", false)
tasks.open()

harness.expect_eq(ownership.owner("phase-x", "t-2"), ownership.HUMAN, "`r` on the cursor task must release it")
harness.expect_eq(vim.fn.getchar(1), 0, "`j` then `r` must not close the float before the trailing `q` is read")

-- 6. `j`/`k` move the cursor between task lines without closing the float or
-- touching ownership — spy on the real nvim_win_set_cursor call open() makes.
local cursor_rows = {}
local real_set_cursor = vim.api.nvim_win_set_cursor
vim.api.nvim_win_set_cursor = function(win, pos)
  table.insert(cursor_rows, pos[1])
  return real_set_cursor(win, pos)
end

vim.api.nvim_feedkeys("jkq", "nt", false)
tasks.open()

vim.api.nvim_win_set_cursor = real_set_cursor

harness.expect_eq(#cursor_rows, 3, "expected one cursor move before the loop plus one per j/k keypress")
harness.expect_eq(
  cursor_rows[1],
  2,
  "the float must open with the cursor on the first task line (row 2, below the header)"
)
harness.expect_eq(cursor_rows[2], 3, "`j` must move the cursor to the second task line")
harness.expect_eq(cursor_rows[3], 2, "`k` must move the cursor back to the first task line")
harness.expect_eq(ownership.owner("phase-x", "t-1"), ownership.CLAUDE, "j/k must not change ownership")
harness.expect_eq(ownership.owner("phase-x", "t-2"), ownership.HUMAN, "j/k must not change ownership")
harness.expect_eq(vim.fn.getchar(1), 0, "j/k must not close the float before the trailing `q` is read")

-- 7. The header line is still the first line of the real buffer opened by
-- open()/_show(), above the task lines — unchanged by adding `c`/`r`/`j`/`k`.
-- Captured inside the spy itself, before the buffer is wiped on close: `q`
-- closes the float synchronously inside tasks.open(), so reading the buffer
-- back afterwards would hit an already-wiped id (bufhidden = "wipe").
local shown_lines
local real_show = tasks._show
tasks._show = function(lines)
  local buf, win = real_show(lines)
  shown_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return buf, win
end

vim.api.nvim_feedkeys("q", "nt", false)
tasks.open()

tasks._show = real_show

harness.expect_contains(shown_lines[1], "yours:", "the header must be the first line of the real buffer")
harness.expect_contains(shown_lines[2], "t-1", "the first task line must come right after the header")

-- 8. Claiming/releasing via `c`/`r` prunes a stale ownership entry for a task
-- id no longer in the phase's plan.toml, same as :CodriverClaim (t-3).
ownership.claim("phase-x", "t-stale")

vim.api.nvim_feedkeys("rq", "nt", false)
tasks.open()

harness.expect_eq(
  ownership.owner("phase-x", "t-stale"),
  ownership.HUMAN,
  "a real c/r write from the float must prune a stale entry for a task id absent from plan.toml"
)

-- 9. `d` marks the task under the cursor done via codriver.task_status.set,
-- and `u` reverts it back to in_progress (task-status-sync's write-through
-- keys). vim.system is faked per-case so no real dross process is needed for
-- the argv/re-render/ownership assertions; the real end-to-end write is
-- proven separately below, guarded on `dross` actually being on PATH.
-- step 8's `r` press released t-1 (the cursor's default row) as a side
-- effect, so re-claim it here for a known starting point.
ownership.claim("phase-x", "t-1")
harness.expect_eq(ownership.owner("phase-x", "t-1"), ownership.CLAUDE, "t-1 re-claimed for a known starting point")

local real_system = vim.system
local captured_cmd

vim.system = function(cmd, opts)
  captured_cmd = { cmd = cmd, opts = opts }
  return {
    wait = function()
      return { code = 0 }
    end,
  }
end

vim.api.nvim_feedkeys("dq", "nt", false)
tasks.open()

vim.system = real_system

harness.expect(
  vim.deep_equal(captured_cmd.cmd, { "dross", "task", "status", "phase-x", "t-1", "done" }),
  "`d` must call vim.system with the dross task status argv for the cursor task"
)
harness.expect(captured_cmd.opts.text, "`d` must call vim.system with {text = true}")
harness.expect_eq(vim.fn.getchar(1), 0, "`d` must not close the float before the trailing `q` is read")
harness.expect_eq(
  ownership.owner("phase-x", "t-1"),
  ownership.CLAUDE,
  "`d` must not touch ownership for the task acted on"
)

captured_cmd = nil
vim.system = function(cmd, opts)
  captured_cmd = { cmd = cmd, opts = opts }
  return {
    wait = function()
      return { code = 0 }
    end,
  }
end

vim.api.nvim_feedkeys("uq", "nt", false)
tasks.open()

vim.system = real_system

harness.expect(
  vim.deep_equal(captured_cmd.cmd, { "dross", "task", "status", "phase-x", "t-1", "in_progress" }),
  "`u` must call vim.system with the dross task status argv for the cursor task"
)
harness.expect_eq(vim.fn.getchar(1), 0, "`u` must not close the float before the trailing `q` is read")
harness.expect_eq(
  ownership.owner("phase-x", "t-1"),
  ownership.CLAUDE,
  "`u` must not touch ownership for the task acted on"
)

-- 10. A failed write (non-zero exit) notifies at ERROR with the failure
-- message, and still re-renders without closing or crashing.
local failure_notifications = capture_notifications(function()
  vim.system = function()
    return {
      wait = function()
        return { code = 1, stderr = "invalid status transition", stdout = "" }
      end,
    }
  end
  vim.api.nvim_feedkeys("dq", "nt", false)
  tasks.open()
  vim.system = real_system
end)

harness.expect(#failure_notifications >= 1, "expected a notification when the write fails")
harness.expect_eq(failure_notifications[1].level, vim.log.levels.ERROR, "a failed write's notification must be ERROR")
harness.expect_contains(
  failure_notifications[1].msg,
  "invalid status transition",
  "the notification must carry the failure message"
)

-- 11. A spawn failure (vim.system itself raising, e.g. dross missing from
-- PATH) still notifies and does not crash the key loop or leave the float
-- open.
local spawn_ok, spawn_notifications = pcall(function()
  return capture_notifications(function()
    vim.system = function()
      error("ENOENT: dross not found")
    end
    vim.api.nvim_feedkeys("dq", "nt", false)
    tasks.open()
    vim.system = real_system
  end)
end)

harness.expect(spawn_ok, "a spawn failure inside task_status.set must not raise out of open()")
harness.expect(#spawn_notifications >= 1, "expected a notification when the spawn itself fails")
harness.expect_eq(spawn_notifications[1].level, vim.log.levels.ERROR, "a spawn failure's notification must be ERROR")

-- 12. When `dross` is actually on PATH: pressing `d` through the real CLI
-- updates the sandbox fixture's plan.toml status field on disk. Guarded and
-- skipped (not failed) when the binary is unavailable — this proves the CLI
-- integration, it does not require dross be installed to run the suite.
if vim.fn.executable("dross") == 1 then
  harness.write(
    PROJECT .. "/.dross/project.toml",
    table.concat({
      "[project]",
      '  name = "fixture"',
      '  version = "0.0.0.0"',
      "",
      "[stack]",
      "",
      "[runtime]",
      "",
      "[repo]",
      "",
      "[remote]",
      "",
      "[paths]",
      "",
      "[env]",
      "",
      "[goals]",
    }, "\n")
  )

  vim.api.nvim_feedkeys("dq", "nt", false)
  tasks.open()

  local plan_text = table.concat(vim.fn.readfile(PROJECT .. "/.dross/phases/phase-x/plan.toml"), "\n")
  harness.expect_match(
    plan_text,
    'id%s*=%s*"t%-1".-status%s*=%s*"done"',
    "real dross CLI must persist t-1's status as done in plan.toml"
  )
else
  print(harness.name .. ": skipping real-dross case — `dross` not on PATH")
end

vim.fn.chdir(harness.repo_root)

harness.ok(
  "no active phase and a corrupt plan.toml both notify without opening a window or erroring, a valid plan.toml "
    .. "renders id/title/status/owner into a real read-only buffer, any keypress not bound to an action closes the "
    .. "real float, `c`/`r` claim/release the task under the cursor without closing, `j`/`k` move the cursor "
    .. "without closing or touching ownership, the header stays the first line of the real buffer, a real c/r "
    .. "write prunes a stale ownership entry for a task id absent from plan.toml, `d`/`u` call codriver.task_status "
    .. "with the right argv and re-render without touching ownership, a failed write notifies at ERROR without "
    .. "leaving a stale status, a spawn failure notifies without crashing, and (when dross is on PATH) a real `d` "
    .. "persists the new status to plan.toml on disk"
)
