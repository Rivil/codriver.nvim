-- t-2 / c-3: :CodriverClaim's own command wiring (claim_command in init.lua) —
-- run under real Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/codriver_claim_check.lua
--
-- ownership_spec.lua already proves claim()/owner()/is_known() as pure
-- functions; this file is only for the claims that need the real command
-- handler wired through a real dross.read() over a real cwd — no active
-- phase, and an id absent from the current task list — the same reason
-- dross_untracked_notify_check.lua exists for start_command's own dross.read()
-- integration rather than a busted spec.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

-- Moved before setup() runs at all: dross.read() reads vim.fn.getcwd()
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

local ownership = require("codriver.ownership")

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

-- 1. No .dross/ at all: WARNs "nothing to claim" and does not raise. Nothing
-- to record either — there is no phase id to key the store on.
local no_phase_notifications = capture(function()
  vim.cmd("CodriverClaim t-1")
end)

harness.expect(#no_phase_notifications >= 1, "expected a notification when there is no active dross phase")
harness.expect_contains(no_phase_notifications[1].msg, "nothing to claim", "no-active-phase notification text")
harness.expect_eq(
  no_phase_notifications[1].level,
  vim.log.levels.WARN,
  "the no-active-phase notification must be a WARN"
)

-- 2. An active phase with a known task list: claiming an id absent from it
-- still records the claim, but WARNs about the id.
harness.write(PROJECT .. "/.dross/state.json", vim.json.encode({ current_phase = "phase-x" }))
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
  }, "\n")
)

local unknown_id_notifications = capture(function()
  vim.cmd("CodriverClaim t-9")
end)

harness.expect(#unknown_id_notifications >= 1, "expected a notification when the claimed id is not in the task list")
harness.expect_contains(unknown_id_notifications[1].msg, "t-9", "unknown-id notification names the id")
harness.expect_eq(
  unknown_id_notifications[1].level,
  vim.log.levels.WARN,
  "the unknown-id notification must be a WARN"
)
harness.expect_eq(ownership.owner("phase-x", "t-9"), ownership.CLAUDE, "the claim on an unknown id must still record")

-- 3. Claiming an id that IS in the task list: recorded, and no WARN at all.
local known_id_notifications = capture(function()
  vim.cmd("CodriverClaim t-1")
end)

harness.expect_eq(#known_id_notifications, 0, "claiming a known task id must not notify")
harness.expect_eq(ownership.owner("phase-x", "t-1"), ownership.CLAUDE, "the claim on a known id must record")

-- 4. Explicit `claude` arg claims the same as the bare form.
local explicit_claude_notifications = capture(function()
  vim.cmd("CodriverClaim t-1 claude")
end)

harness.expect_eq(#explicit_claude_notifications, 0, "`<id> claude` on a known task id must not notify")
harness.expect_eq(ownership.owner("phase-x", "t-1"), ownership.CLAUDE, "`<id> claude` must still record the claim")

-- 5. `<id> human` releases a previously-claimed task back to human.
local release_notifications = capture(function()
  vim.cmd("CodriverClaim t-1 human")
end)

harness.expect_eq(#release_notifications, 0, "releasing a known task id must not notify")
harness.expect_eq(ownership.owner("phase-x", "t-1"), ownership.HUMAN, "`<id> human` must release the claim")

-- 6. An unrecognized second argument WARNs and leaves ownership untouched.
ownership.claim("phase-x", "t-1")

local bad_arg_notifications = capture(function()
  vim.cmd("CodriverClaim t-1 nonsense")
end)

harness.expect(#bad_arg_notifications >= 1, "expected a notification for an unrecognized owner arg")
harness.expect_contains(bad_arg_notifications[1].msg, "nonsense", "unrecognized-arg notification names the arg")
harness.expect_eq(
  bad_arg_notifications[1].level,
  vim.log.levels.WARN,
  "the unrecognized-arg notification must be a WARN"
)
harness.expect_eq(
  ownership.owner("phase-x", "t-1"),
  ownership.CLAUDE,
  "an unrecognized owner arg must leave the existing claim unchanged"
)

-- 7. Claiming/releasing through the real command drops a stale ownership
-- entry for a task id no longer in the phase's plan.toml, same as the pure
-- claim()/release() pruning already proven in ownership_spec.lua — this only
-- proves the real command wires the current task list through.
ownership.claim("phase-x", "t-stale")

vim.cmd("CodriverClaim t-1 human")

harness.expect_eq(
  ownership.owner("phase-x", "t-stale"),
  ownership.HUMAN,
  "a real :CodriverClaim release must prune a stale entry for a task id absent from plan.toml"
)

vim.fn.chdir(harness.repo_root)

harness.ok(
  ":CodriverClaim WARNs and records nothing when there is no active dross phase, WARNs but still records when the "
    .. "id is absent from the current task list, claims a known id silently with the bare or 'claude' form, "
    .. "releases with 'human', WARNs and leaves ownership unchanged for an unrecognized owner arg, and prunes stale "
    .. "entries for ids absent from the current task list on every real claim/release"
)
