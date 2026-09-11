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

vim.fn.chdir(harness.repo_root)

harness.ok(
  "no active phase and a corrupt plan.toml both notify without opening a window or erroring, a valid plan.toml "
    .. "renders id/title/status/owner into a real read-only buffer, any keypress not bound to an action closes the "
    .. "real float, `c`/`r` claim/release the task under the cursor without closing, `j`/`k` move the cursor "
    .. "without closing or touching ownership, the header stays the first line of the real buffer, and a real "
    .. "c/r write prunes a stale ownership entry for a task id absent from plan.toml"
)
