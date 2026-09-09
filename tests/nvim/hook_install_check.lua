-- Arm on session start, disarm on stop — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/hook_install_check.lua
--
-- Drives a real `:CodriverStart` / `:CodriverStop` cycle (fake terminal
-- provider, so nothing actually spawns `claude`) against a scratch project
-- directory, and inspects the real `.claude/settings.local.json` it writes.
-- session_spec.lua already proves the wrapper logic against fakes; this file
-- is only for claims that need the real filesystem, a real cwd, and a real
-- registered command to mean anything.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local claude_settings = require("codriver.hook.claude_settings")
local session = require("codriver.session")
local state = require("codriver.hook.state")

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

-- 8. This repo's own settings file, snapshotted before anything runs. mise's
-- test-nvim task launches every check from the repo root, so an unpinned cwd
-- here would arm the developer's own next Claude Code session.
local REAL_SETTINGS = harness.repo_root .. "/.claude/settings.local.json"
local function snapshot_real_settings()
  if vim.fn.filereadable(REAL_SETTINGS) == 1 then
    return table.concat(vim.fn.readfile(REAL_SETTINGS), "\n")
  end
  return nil
end
local real_settings_before = snapshot_real_settings()

-- Moved before setup() runs at all: ensure_server() reads vim.fn.getcwd()
-- itself, and codriver.setup() must never see the repo root as cwd here.
local PROJECT = harness.sandbox_root .. "/project"
vim.fn.mkdir(PROJECT, "p")
vim.fn.chdir(PROJECT)

local SETTINGS_PATH = PROJECT .. "/.claude/settings.local.json"

-- 1. Ordering, proven against the real install() rather than a recorder that
-- stands in for it: wrapped, not replaced, so the file on disk is real too.
local events = {}
local real_install = claude_settings.install
claude_settings.install = function(path, command)
  table.insert(events, "claude_settings.install")
  return real_install(path, command)
end

local provider = {
  setup = function() end,
  open = function()
    table.insert(events, "terminal.open")
  end,
  close = function() end,
  simple_toggle = function() end,
  focus_toggle = function() end,
  get_active_bufnr = function()
    return nil
  end,
  is_available = function()
    return true
  end,
}

require("codriver").setup({
  test_command = "mise run test",
  claudecode = { terminal = { provider = provider } },
})

vim.cmd("CodriverStart")

harness.expect(
  #events == 2 and events[1] == "claude_settings.install" and events[2] == "terminal.open",
  "expected [claude_settings.install, terminal.open], got %s",
  vim.inspect(events)
)

-- 3. The registration lands at vim.fn.getcwd() under the default
-- configuration — read back from disk, not recomputed independently.
harness.expect_eq(vim.fn.filereadable(SETTINGS_PATH), 1, "no settings file was written at vim.fn.getcwd()")
local doc = vim.json.decode(table.concat(vim.fn.readfile(SETTINGS_PATH), "\n"))
harness.expect_eq(#doc.hooks.PreToolUse, 1, "expected exactly one registered PreToolUse entry")
local command = doc.hooks.PreToolUse[1].hooks[1].command

-- 5. The registered command path resolves and is actually runnable by
-- `nvim -l` — a moved plugin dir leaves a stale absolute path here and
-- silent non-enforcement, so this is asserted by running it, not by parsing.
local script_path = command:match("^nvim %-%-clean %-l (.+)$")
harness.expect(script_path ~= nil, "could not parse a script path out of the registered command %q", command)
harness.expect_eq(
  vim.fn.filereadable(script_path),
  1,
  "the registered hook script does not exist at " .. tostring(script_path)
)

local run_result = harness.run({ "nvim", "--clean", "-l", script_path }, { stdin = "{}", timeout = 10000 })
harness.expect_eq(run_result.code, 0, "the registered command failed to run: " .. tostring(run_result.stderr))

-- 7. stop() disarms: the state file goes, even though the settings entry
-- deliberately survives (settings_delivery's accepted cost).
vim.cmd("CodriverStop")
harness.expect_eq(vim.fn.filereadable(state.path()), 0, "session.stop() must clear the state file")

-- 6. install() is idempotent across a start/stop/start cycle: still exactly
-- one codriver PreToolUse entry, not two.
vim.cmd("CodriverStart")
local doc_after_cycle = vim.json.decode(table.concat(vim.fn.readfile(SETTINGS_PATH), "\n"))
harness.expect_eq(
  #doc_after_cycle.hooks.PreToolUse,
  1,
  "a start/stop/start cycle must not leave two codriver PreToolUse entries"
)

vim.cmd("CodriverStop")

-- 4. A non-default terminal cwd is out of this phase's scope and must warn
-- once, by name, rather than silently arming vim.fn.getcwd() instead.
local notifications = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
  table.insert(notifications, { msg = msg, level = level })
end

session._reset()
require("codriver").setup({
  claudecode = { terminal = { provider = provider, cwd = "/somewhere/else" } },
})
session.ensure_server()

vim.notify = real_notify

harness.expect_eq(#notifications, 1, "expected exactly one cwd-scope warning")
harness.expect_eq(notifications[1].level, vim.log.levels.WARN, "the cwd-scope warning must be a WARN")
harness.expect(
  notifications[1].msg:lower():find("cwd", 1, true) ~= nil,
  "the warning must name the cwd option, got %s",
  notifications[1].msg
)

vim.cmd("CodriverStop")

-- 8. Never arms the developer's own repository, regardless of everything
-- above having run with cwd inside a temp project dir the whole time.
vim.fn.chdir(harness.repo_root)
harness.expect_eq(
  snapshot_real_settings(),
  real_settings_before,
  "this repository's own .claude/settings.local.json changed during the check"
)

harness.ok(
  "ensure_server() arms before the terminal opens (even on re-preflight), registers at vim.fn.getcwd() with a "
    .. "command that actually runs, stays idempotent across a start/stop/start cycle, stop() disarms by clearing "
    .. "the state file, a non-default terminal cwd warns exactly once, and the developer's own repo settings file "
    .. "is never touched"
)
