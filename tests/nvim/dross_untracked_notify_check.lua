-- c-1 / c-5: a session with no active dross phase says so, once, on start —
-- run under real Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/dross_untracked_notify_check.lua
--
-- Drives a real `:CodriverStart` against a scratch project directory with a
-- real (absent, then present) `.dross/`, and inspects real `vim.notify`
-- calls. init_spec.lua already proves start_command's other notifications
-- against fakes; this file is only for the claim that needs a real cwd and a
-- real `.dross/state.json` to mean anything.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

-- Moved before setup() runs at all: dross.read() (via ensure_server()'s own
-- cwd-dependent arming, and now start_command itself) reads vim.fn.getcwd()
-- directly, and codriver.setup() must never see the repo root's own real,
-- tracked `.dross/` as cwd here.
local PROJECT = harness.sandbox_root .. "/project"
vim.fn.mkdir(PROJECT, "p")
vim.fn.chdir(PROJECT)

local provider = {
  setup = function() end,
  open = function() end,
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
  claudecode = { terminal = { provider = provider } },
})

---@return { msg: string, level: integer }[]
local function capture(fn)
  local notifications = {}
  local real_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end

  fn()

  vim.notify = real_notify
  return notifications
end

---@param notifications { msg: string, level: integer }[]
---@return { msg: string, level: integer }[]
local function untracked_notifications(notifications)
  local matches = {}
  for _, n in ipairs(notifications) do
    if n.msg:lower():find("untracked", 1, true) then
      table.insert(matches, n)
    end
  end
  return matches
end

-- 1. No .dross/ at all: exactly one WARN mentioning "untracked", and the
-- start itself must not raise.
local no_dross_notifications = capture(function()
  vim.cmd("CodriverStart")
end)
local no_dross_matches = untracked_notifications(no_dross_notifications)

harness.expect_eq(#no_dross_matches, 1, "expected exactly one untracked notification with no .dross/ present")
harness.expect_eq(no_dross_matches[1].level, vim.log.levels.WARN, "the untracked notification must be a WARN")

vim.cmd("CodriverStop")

-- 2. An active phase in state.json: no untracked warning at all.
harness.write(
  PROJECT .. "/.dross/state.json",
  vim.json.encode({ current_phase = "phase-x", current_phase_status = "planned" })
)

local tracked_notifications = capture(function()
  vim.cmd("CodriverStart")
end)
local tracked_matches = untracked_notifications(tracked_notifications)

harness.expect_eq(#tracked_matches, 0, "expected no untracked notification with an active phase in state.json")

vim.cmd("CodriverStop")

vim.fn.chdir(harness.repo_root)

harness.ok(
  "starting a session with no .dross/ present fires exactly one WARN-level untracked notification without "
    .. "raising, and an active phase in state.json emits none"
)
