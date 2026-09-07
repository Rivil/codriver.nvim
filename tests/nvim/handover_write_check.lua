-- End-to-end handover/takeback — run under real Neovim by `mise run test-nvim`,
-- or alone:
--
--   nvim --clean --headless -l tests/nvim/handover_write_check.lua
--
-- Drives the real :CodriverHandover/:CodriverTakeback commands against a
-- single, never-restarted live session, proving c-2 and c-3 end to end: a
-- denied Edit under navigator, :CodriverHandover, the identical payload now
-- allowed without a relaunch, :CodriverTakeback, the identical payload denied
-- again with the same refusal guarantees as role-enforcement — and the target
-- file byte-identical throughout.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local state = require("codriver.hook.state")

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

local TEST_COMMAND = "mise run test"

-- A real, live setup() session in this very process, never torn down or
-- re-run below — its state file is keyed on this process's own pid, which
-- stays alive for the whole check, so :CodriverHandover/:CodriverTakeback
-- republish against a genuinely live record without any restart.
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
  test_command = TEST_COMMAND,
  claudecode = { terminal = { provider = provider } },
})

local LIVE_ENV = { CODRIVER_STATE_FILE = state.path() }

local fixture = harness.sandbox_root .. "/fixture.lua"
local fixture_content = "-- fixture\nreturn 42"
harness.write(fixture, fixture_content)

---@return string
local function fixture_sha()
  return vim.fn.sha256(table.concat(vim.fn.readfile(fixture), "\n"))
end

local sha_before = fixture_sha()

---@return { code: integer, stdout: string, stderr: string }
local function run_edit()
  return harness.run_hook({
    hook_event_name = "PreToolUse",
    tool_name = "Edit",
    tool_input = { file_path = fixture },
  }, LIVE_ENV)
end

-- 1. Deny under navigator, the default role for a fresh session.
local navigator_result = run_edit()
harness.expect_eq(navigator_result.code, 0, "navigator: must exit 0")
harness.expect(navigator_result.stdout ~= "", "expected a deny for Edit while navigator")
harness.expect_eq(fixture_sha(), sha_before, "a denied Edit must leave its target file byte-identical")

-- 2. :CodriverHandover — the real command, not role.set() called directly —
-- must take effect for the live hook process without restarting the session.
vim.cmd("CodriverHandover")

local handover_result = run_edit()
harness.expect_eq(handover_result.code, 0, "after handover: must exit 0")
harness.expect_eq(
  handover_result.stdout,
  "",
  "the identical Edit payload must be allowed after :CodriverHandover, with no process restart"
)
harness.expect_eq(fixture_sha(), sha_before, "the target file must stay byte-identical after a handover")

-- 3. :CodriverTakeback re-blocks the same session, same refusal guarantees.
vim.cmd("CodriverTakeback")

local takeback_result = run_edit()
harness.expect_eq(takeback_result.code, 0, "after takeback: must exit 0")
harness.expect(takeback_result.stdout ~= "", "expected a deny for Edit again after :CodriverTakeback")

-- Decoded, not a raw string comparison: `vim.json.encode`'s key order is not
-- stable across the two separate hook subprocesses that produced each
-- document, only their content is.
local navigator_decoded = vim.json.decode(navigator_result.stdout)
local takeback_decoded = vim.json.decode(takeback_result.stdout)
harness.expect_eq(
  takeback_decoded.hookSpecificOutput.permissionDecisionReason,
  navigator_decoded.hookSpecificOutput.permissionDecisionReason,
  ":CodriverTakeback must re-block with the same refusal reason as the original deny"
)
harness.expect_eq(
  takeback_decoded.hookSpecificOutput.permissionDecision,
  navigator_decoded.hookSpecificOutput.permissionDecision,
  ":CodriverTakeback must re-block with the same permission decision as the original deny"
)
harness.expect_eq(fixture_sha(), sha_before, "the target file must stay byte-identical after a takeback")

harness.ok(
  ":CodriverHandover unblocks a live denied Edit and :CodriverTakeback re-blocks it, byte-identically and without "
    .. "restarting the session"
)
