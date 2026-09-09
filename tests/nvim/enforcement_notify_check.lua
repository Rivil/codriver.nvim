-- Headless refusal-notification round-trip check — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/enforcement_notify_check.lua
--
-- c-8 is specifically about learning of a refusal WITHOUT reading the Claude
-- terminal, so arrival is established by observing the editor — vim.notify,
-- stubbed in this live instance — never by reading the hook's stdout.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local state = require("codriver.hook.state")

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

local TEST_COMMAND = "mise run test"

---@param role string
---@return table
local function live_env(role)
  vim.fn.delete(state.path())
  state.publish({ role = role, test_command = TEST_COMMAND })
  return { CODRIVER_STATE_FILE = state.path() }
end

---A version of harness.run_hook() built on vim.system()'s async form plus
---vim.wait(), rather than SystemObj:wait(). Needed only here: an RPC
---connection the hook subprocess opens back into this process is never
---accepted while this process is blocked inside :wait() — confirmed by
---direct experiment, not documented behaviour — so any check that needs to
---observe the hook's own notify() round-trip has to spawn this way instead.
-- Every other check in this directory only cares about the hook's stdout and
-- exit status, which :wait() reports correctly either way, so this is not
-- pulled into harness.lua for the other six checks that never hit this.
---@param payload table
---@param env table
---@return { code: integer, stdout: string, stderr: string }
local function run_hook_async(payload, env)
  local done, obj = false, nil
  vim.system({ "nvim", "--clean", "-l", harness.repo_root .. "/scripts/codriver-hook.lua" }, {
    text = true,
    env = env,
    stdin = vim.json.encode(payload),
  }, function(result)
    obj = result
    done = true
  end)
  vim.wait(10000, function()
    return done
  end, 20)
  harness.expect(done, "the hook subprocess did not complete within the 10s budget")
  return { code = obj.code, stdout = obj.stdout, stderr = obj.stderr }
end

---@param tool string
---@param tool_input table|nil
---@param env table
---@return { code: integer, stdout: string, stderr: string }
local function run(tool, tool_input, env)
  return run_hook_async({
    hook_event_name = "PreToolUse",
    tool_name = tool,
    tool_input = tool_input,
  }, env)
end

-- Captured refusals. vim.notify itself is stubbed, not notify.refused — this
-- proves the whole chain (subprocess -> RPC -> nvim_exec_lua -> require ->
-- M.refused -> vim.notify), the thing the user actually sees.
local notifications = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
  table.insert(notifications, { msg = msg, level = level })
end

---Poll for at least `n` captured notifications. run_hook_async already
---blocks (via vim.wait) until the subprocess has fully exited, so this is
---purely giving the already-delivered RPC message a chance to be dispatched
---through this process's own event loop, not waiting on the hook itself.
---@param n integer
local function wait_for_notify(n)
  vim.wait(1000, function()
    return #notifications >= n
  end, 20)
end

local ADDRESS = vim.v.servername
harness.expect(
  type(ADDRESS) == "string" and ADDRESS ~= "",
  "this headless check has no servername for the hook subprocess to notify"
)

-- 1. A denied Edit reaches the editor — established purely from the captured
-- notification, never from the hook's stdout.
notifications = {}
local fixture = harness.sandbox_root .. "/fixture.lua"
harness.write(fixture, "return 1")
local deny_env = vim.tbl_extend("force", live_env("navigator"), { CODRIVER_NVIM_ADDRESS = ADDRESS })
run("Edit", { file_path = fixture }, deny_env)
wait_for_notify(1)

harness.expect_eq(#notifications, 1, "expected exactly one notification for a denied Edit")
harness.expect(
  notifications[1].level >= vim.log.levels.WARN,
  "the refusal notification must be at WARN or above, got %s",
  tostring(notifications[1].level)
)
harness.expect(notifications[1].msg:find("Edit", 1, true) ~= nil, "the notification must name the tool (Edit)")
harness.expect(
  notifications[1].msg:find(fixture, 1, true) ~= nil,
  "the notification must name the target path, got: %s",
  notifications[1].msg
)

-- 2. Allowed work must not notify — that chatters at the editor during
-- normal work.
notifications = {}
local allow_env = vim.tbl_extend("force", live_env("navigator"), { CODRIVER_NVIM_ADDRESS = ADDRESS })
run("Read", { file_path = fixture }, allow_env)
wait_for_notify(1)
harness.expect_eq(#notifications, 0, "an allowed Read must not notify")

-- 4. The push is rpcnotify, never a round trip: a channel that is live but
-- never responds must not slow a denied call down relative to an allowed
-- one. Bound to a listener that accepts nothing, ever — real enough to
-- accept a connection, unresponsive from there on, distinct from the
-- plainly dead address in case 5 below.
local unresponsive_address = harness.sandbox_root .. "/unresponsive.sock"
local listener = vim.uv.new_pipe(false)
listener:bind(unresponsive_address)
listener:listen(128, function() end)

local TOLERANCE_MS = 3000
local unresponsive_env =
  vim.tbl_extend("force", live_env("navigator"), { CODRIVER_NVIM_ADDRESS = unresponsive_address })

local deny_start = vim.uv.hrtime()
local deny_result = run("Edit", { file_path = fixture }, unresponsive_env)
local deny_ms = (vim.uv.hrtime() - deny_start) / 1e6
harness.expect_eq(deny_result.code, 0, "a denied call against an unresponsive channel must still exit 0")

local allow_start = vim.uv.hrtime()
local allow_result = run("Read", { file_path = fixture }, unresponsive_env)
local allow_ms = (vim.uv.hrtime() - allow_start) / 1e6
harness.expect_eq(allow_result.code, 0, "an allowed call against an unresponsive channel must still exit 0")

harness.expect(
  deny_ms - allow_ms < TOLERANCE_MS,
  "a denied call against an unresponsive channel took %.0fms longer than an allowed one (tolerance %dms) — the "
    .. "notification push is blocking the decision",
  deny_ms - allow_ms,
  TOLERANCE_MS
)

-- 5. A dead RPC address must yield a clean deny with zero notifications —
-- never a hang, a crash, or a changed decision.
notifications = {}
local dead_env =
  vim.tbl_extend("force", live_env("navigator"), { CODRIVER_NVIM_ADDRESS = harness.sandbox_root .. "/no-such-socket" })
local dead_result = run("Edit", { file_path = fixture }, dead_env)
wait_for_notify(1)

harness.expect_eq(dead_result.code, 0, "a dead notify address must still exit 0 with a clean deny")
harness.expect(
  dead_result.stdout ~= nil and dead_result.stdout ~= "",
  "a dead notify address must still emit the deny document"
)
local ok, decoded = pcall(vim.json.decode, dead_result.stdout)
harness.expect(
  ok
    and type(decoded) == "table"
    and decoded.hookSpecificOutput
    and decoded.hookSpecificOutput.permissionDecision == "deny",
  "a dead notify address must still produce a clean deny document, got stdout: %s",
  dead_result.stdout
)
harness.expect_eq(#notifications, 0, "a dead notify address must produce zero notifications")

vim.notify = real_notify

harness.ok(
  "a denied Edit is learned of purely by observing vim.notify (never the hook's stdout), allowed work stays "
    .. "silent, an unresponsive-but-live channel does not slow a denied call down relative to an allowed one, and "
    .. "a dead channel still yields a clean deny with zero notifications"
)
