-- Headless liveness and fail-closed check — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/enforcement_liveness_check.lua
--
-- Proves the decision reads live role state at call time rather than a
-- value fixed at launch (c-6), and that an unreadable role inside a live
-- session refuses while no session at all allows (c-7).

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local role = require("codriver.role")
local state = require("codriver.hook.state")

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

local TEST_COMMAND = "mise run test"
local EDIT_PAYLOAD = { hook_event_name = "PreToolUse", tool_name = "Edit", tool_input = { file_path = "x" } }

---@param env table
---@return { code: integer, stdout: string, stderr: string }, table|nil
local function run(env)
  local result = harness.run_hook(EDIT_PAYLOAD, env)
  local decoded = nil
  if result.stdout and result.stdout ~= "" then
    local ok, parsed = pcall(vim.json.decode, result.stdout)
    decoded = ok and parsed or nil
  end
  return result, decoded
end

---@param decoded table|nil
---@return string|nil
local function reason_of(decoded)
  return type(decoded) == "table"
      and type(decoded.hookSpecificOutput) == "table"
      and decoded.hookSpecificOutput.permissionDecisionReason
    or nil
end

---A pid with no process behind it, proven rather than assumed — mirrors
---hook_state_check.lua's own helper; not shared via harness.lua because this
---task's file list is this check alone.
---@return integer
local function dead_pid()
  for candidate = 999999, 900000, -1 do
    if not vim.uv.kill(candidate, 0) then
      return candidate
    end
  end
  harness.fail("could not find a dead pid to build a stale record with")
  return 0
end

-- A real, live setup() session in this very process — its state file is
-- keyed on this process's own pid, which is alive for the whole check, so
-- role.set() below republishes against a genuinely live record.
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

-- 1. Not fixed at launch: the identical payload, re-run against the SAME
-- already-launched session (no relaunch, no re-read of env by this check),
-- tracks every role flip live.
local navigator_result, navigator_decoded = run(LIVE_ENV)
harness.expect_eq(navigator_result.code, 0, "navigator: must exit 0")
local navigator_reason = reason_of(navigator_decoded)
harness.expect(
  type(navigator_reason) == "string" and navigator_reason:lower():find("navigator", 1, true) ~= nil,
  "expected the initial Edit to deny with the navigator reason, got stdout: %s",
  navigator_result.stdout
)

role.set("driver")
local driver_result = run(LIVE_ENV)
harness.expect_eq(driver_result.code, 0, "driver: must exit 0")
harness.expect_eq(
  driver_result.stdout,
  "",
  'role.set("driver") on the live instance must allow the identical payload without a relaunch'
)

role.set("navigator")
local _, back_decoded = run(LIVE_ENV)
harness.expect_eq(
  reason_of(back_decoded),
  navigator_reason,
  'role.set("navigator") must flip enforcement back on for the identical payload'
)

-- 2. Role comes from the FILE at call time, not the environment: rewriting
-- the state file's role field directly, bypassing role.set()/publish(),
-- must still change the decision.
local raw_doc = vim.json.decode(table.concat(vim.fn.readfile(state.path()), "\n"))
raw_doc.role = "driver"
vim.fn.writefile({ vim.json.encode(raw_doc) }, state.path())

local direct_write_result = run(LIVE_ENV)
harness.expect_eq(
  direct_write_result.stdout,
  "",
  "a role rewritten directly on disk (bypassing role.set()) must still be read live and allow"
)

-- Restored for the fail-closed cases below, which assert against the
-- navigator reason as their contrast.
role.set("navigator")

-- 3. Fail-closed inside a live session: the owning process (this one) stays
-- alive throughout, but the record itself is unreadable in three different
-- ways. Each must deny with the indeterminate reason, never the navigator one.
local function assert_indeterminate(what)
  local result, decoded = run(LIVE_ENV)
  harness.expect_eq(result.code, 0, what .. ": must exit 0")
  local reason = reason_of(decoded)
  harness.expect(
    type(reason) == "string" and reason ~= "",
    "%s: expected a deny with a reason, got stdout: %s",
    what,
    result.stdout
  )
  harness.expect(
    reason ~= navigator_reason,
    "%s: the indeterminate reason must read differently from the navigator reason",
    what
  )
end

-- 3a. Removed.
vim.fn.delete(state.path())
assert_indeterminate("state file removed")

-- 3b. Truncated mid-JSON.
harness.write(state.path(), "{ truncated mid-jso")
assert_indeterminate("state file truncated")

-- 3c. Role rewritten to an invalid value.
vim.fn.writefile({ vim.json.encode({ schema = 1, pid = vim.uv.os_getpid(), role = "nvigator" }) }, state.path())
assert_indeterminate("role rewritten to an invalid value")

-- Republish a real record so the live session is left in a normal state.
state.publish({ role = "navigator", test_command = TEST_COMMAND })

-- 4. The no-session path fails OPEN: a plain `claude` run must keep working
-- when there is nothing live behind it.
local killed_pid = dead_pid()
local killed_path = STATE_HOME .. "/codriver/" .. killed_pid .. ".json"
harness.write(killed_path, vim.json.encode({ schema = 1, pid = killed_pid, role = "navigator" }))

-- 5. A stale record is not trusted regardless of its content: liveness is
-- kill(pid, 0), not the file, so a dead owner allows even though the record
-- itself says navigator.
local killed_result = run({ CODRIVER_STATE_FILE = killed_path })
harness.expect_eq(killed_result.code, 0, "dead instance: must exit 0")
harness.expect_eq(
  killed_result.stdout,
  "",
  "a state file whose owning pid is dead must allow, even though its contents say navigator"
)

-- 4b. CODRIVER_* entirely absent from the environment — not merely empty.
local absent_result = run({})
harness.expect_eq(absent_result.code, 0, "no CODRIVER_* env at all: must exit 0")
harness.expect_eq(absent_result.stdout, "", "a plain `claude` run with no codriver env at all must be allowed")

harness.ok(
  "the decision reads live role state at call time — flipping role.set() and rewriting the state file directly on "
    .. "disk both change the identical payload's outcome without a relaunch — a live session with an unreadable "
    .. "record fails closed with the indeterminate reason in three different corruption shapes, and no session at "
    .. "all (a dead owning pid, or no CODRIVER_* env at all) fails open"
)
