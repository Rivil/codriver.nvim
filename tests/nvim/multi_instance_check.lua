-- Multi-instance role isolation — run under real Neovim by `mise run test-nvim`,
-- or alone:
--
--   nvim --clean --headless -l tests/nvim/multi_instance_check.lua
--
-- Per the multi_instance_tiebreak decision, each live Claude session's role is
-- decided solely by whichever Neovim instance opened it: the state file is
-- keyed on that instance's own pid, and no instance ever writes to another's
-- file. There is no shared resource to race, so there is no tie to break — this
-- proves that by publishing two concurrently-live per-pid records with opposite
-- roles and showing a hook process pointed at one is never swayed by the
-- other's (c-5).

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

local EDIT_PAYLOAD = { hook_event_name = "PreToolUse", tool_name = "Edit", tool_input = { file_path = "x" } }

---@param env table
---@return { code: integer, stdout: string, stderr: string }
local function run(env)
  return harness.run_hook(EDIT_PAYLOAD, env)
end

---Spawn a real, long-lived process so `vim.uv.kill(pid, 0)` sees a genuinely
---live instance behind its state file — a synthetic pid would only prove the
---decision reads the record, not that liveness itself is instance-scoped.
---@return integer pid, vim.SystemObj handle
local function spawn_instance()
  local handle = vim.system({ "sleep", "60" }, {})
  return handle.pid, handle
end

---Per-pid record path, mirroring `codriver.hook.state.path()` for a pid other
---than this process's own.
---@param pid integer
---@return string
local function record_path(pid)
  return ("%s/codriver/%d.json"):format(STATE_HOME, pid)
end

---@param pid integer
---@param role string
local function publish(pid, role)
  harness.write(record_path(pid), vim.json.encode({ schema = 1, pid = pid, role = role }))
end

local a_pid, a_handle = spawn_instance()
local b_pid, b_handle = spawn_instance()

-- 1. Two concurrently-live instances, opposite roles, no shared file between
-- them: A is driver, B is navigator.
publish(a_pid, "driver")
publish(b_pid, "navigator")

local a_path = record_path(a_pid)
local b_path = record_path(b_pid)

local a_result = run({ CODRIVER_STATE_FILE = a_path })
harness.expect_eq(a_result.code, 0, "instance A: must exit 0")
harness.expect_eq(
  a_result.stdout,
  "",
  "instance A (driver) must allow the Edit regardless of instance B's concurrently-published navigator role"
)

local b_result = run({ CODRIVER_STATE_FILE = b_path })
harness.expect_eq(b_result.code, 0, "instance B: must exit 0")
harness.expect(
  b_result.stdout ~= "",
  "instance B (navigator) must deny the Edit regardless of instance A's concurrently-published driver role"
)

-- 2. A stays unaffected by anything that happens to B below — proven again
-- after B changes, not just once up front.
local a_result_again = run({ CODRIVER_STATE_FILE = a_path })
harness.expect_eq(a_result_again.stdout, "", "instance A must still allow after instance B's record is touched")

-- 3. Overwriting B's OWN record wins immediately for a hook process pointed at
-- B's file — the isolation is per-file, not a frozen snapshot.
publish(b_pid, "driver")

local b_result_after = run({ CODRIVER_STATE_FILE = b_path })
harness.expect_eq(b_result_after.code, 0, "instance B after flipping to driver: must exit 0")
harness.expect_eq(
  b_result_after.stdout,
  "",
  "instance B's own record flipping to driver must allow the identical payload for a hook pointed at B's file"
)

a_handle:kill(15)
b_handle:kill(15)
a_handle:wait()
b_handle:wait()

harness.ok(
  "a hook process pointed at instance A's state file is never swayed by instance B's concurrently-published role, "
    .. "and overwriting instance B's own record wins immediately for a hook process pointed at B's file"
)
