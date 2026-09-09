-- Session lifecycle — run under real Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/session_lifecycle_check.lua
--
-- Drives the real `:CodriverStart` / `:CodriverStop` against the real WebSocket
-- server and the harness's sandboxed lock directory. It deliberately overlaps
-- tests/codriver/session_spec.lua, which drives the same paths against a fake:
-- this is what keeps that fake honest about the real module's shape (c-1, c-5).
--
-- The `track_selection = false` scenario runs *first* and on purpose. The
-- vendored `ClaudeCodeSelection` augroup, once created, outlives the session
-- that created it — so "never created at all" is only observable before
-- anything has armed it.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

---A terminal provider that puts nothing on screen. `:CodriverStart` opens a
---terminal along with the session, and a headless process has nowhere to put
---one — nor any business launching a real `claude`. The seven functions are the
---vendored provider contract.
---@return table
local function stub_provider()
  local provider = { calls = {} }
  for _, name in ipairs({ "setup", "open", "close", "simple_toggle", "focus_toggle" }) do
    provider[name] = function()
      table.insert(provider.calls, name)
    end
  end
  provider.get_active_bufnr = function()
    return nil
  end
  provider.is_available = function()
    return true
  end
  return provider
end

local codriver = require("codriver")
local server = require("codriver.vendor.claudecode.server.init")

---Everything `vim.notify` was handed, with its level. The rendered text alone
---cannot tell an error from a plain report, and "a second start is not a
---failure" is a claim about the level.
local notified = {}
do
  local real_notify = vim.notify
  vim.notify = function(msg, level, opts)
    table.insert(notified, { msg = tostring(msg), level = level })
    return real_notify(msg, level, opts)
  end
end

local function last_notified()
  return notified[#notified] or { msg = "", level = nil }
end

---Autocommands in the vendored selection augroup, or nil when the group has
---never been created. `nvim_get_autocmds` raises on an unknown group, which is
---the distinction this check needs.
---@return table[]|nil
local function selection_autocmds()
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "ClaudeCodeSelection" })
  if not ok then
    return nil
  end
  return autocmds
end

---@param opts table|nil vendored options, merged over a stub terminal provider
local function setup(opts)
  local claudecode = vim.tbl_extend("force", { terminal = { provider = stub_provider() } }, opts or {})
  codriver.setup({ claudecode = claudecode })
end

---The basename of the single lockfile, or a description of why there isn't one.
---@return string
local function lock_names()
  local locks = harness.lock_files()
  local names = {}
  for _, path in ipairs(locks) do
    table.insert(names, vim.fn.fnamemodify(path, ":t"))
  end
  return #names > 0 and table.concat(names, ", ") or "(none)"
end

-- ------------------------------------------------- track_selection = false ---
-- First, while "never created" is still observable.

setup({ track_selection = false })
vim.cmd("CodriverStart")

harness.expect_eq(server.get_status().running, true, "the session did not start with track_selection = false")
harness.expect(
  selection_autocmds() == nil,
  "ClaudeCodeSelection was created despite track_selection = false — the opt-out is inert"
)

local opted_out_stop_ok, opted_out_stop_err = pcall(vim.cmd, "CodriverStop")
harness.expect(opted_out_stop_ok, "stop threw with track_selection = false: %s", tostring(opted_out_stop_err))
harness.expect_eq(#harness.lock_files(), 0, "lockfile left behind: " .. lock_names())

-- ------------------------------------------------------------------ start ---

setup()

local start_output = vim.fn.execute("CodriverStart")
local status = server.get_status()
local first_port = status.port

harness.expect_eq(status.running, true, "CodriverStart did not bring the server up")
harness.expect(type(first_port) == "number", "the server reports no port")
harness.expect_contains(
  start_output,
  tostring(first_port),
  "the start output does not name the port it is listening on"
)
harness.expect_eq(#harness.lock_files(), 1, "expected exactly one lockfile, got " .. lock_names())
harness.expect_eq(lock_names(), ("%d.lock"):format(first_port), "the lockfile is not named for the listening port")

-- Selection tracking follows the session, and the vendored start is what arms
-- it — a wrapper that armed it itself would make the opt-out above inert.
local armed = selection_autocmds()
harness.expect(armed and #armed > 0, "selection tracking is not armed after start")

-- ----------------------------------------------------------- start, again ---
-- Asking for a session you already have tells you where it is. It is not a
-- failure, and it must not produce a second server or a second lockfile (c-1).

local again_output = vim.fn.execute("CodriverStart")

harness.expect_eq(server.get_status().port, first_port, "a second start moved the port")
harness.expect_eq(#harness.lock_files(), 1, "a second start wrote another lockfile: " .. lock_names())
harness.expect_contains(again_output, tostring(first_port), "the second start does not name the live port")
harness.expect_match(again_output:lower(), "already", "the second start does not report the session it already has")
harness.expect(
  last_notified().level ~= vim.log.levels.ERROR,
  "a second start was reported at error level: " .. last_notified().msg
)

-- ------------------------------------------------------------------- stop ---

local lock_path = harness.lock_dir .. "/" .. first_port .. ".lock"

local stop_ok, stop_err = pcall(vim.cmd, "CodriverStop")
harness.expect(stop_ok, "CodriverStop threw: %s", tostring(stop_err))
harness.expect_eq(server.get_status().running, false, "the server is still running after CodriverStop")
harness.expect_eq(vim.fn.filereadable(lock_path), 0, "the lockfile survived CodriverStop: " .. lock_path)
harness.expect_eq(#harness.lock_files(), 0, "lockfiles left behind after stop: " .. lock_names())

local cleared = selection_autocmds()
harness.expect(cleared ~= nil and #cleared == 0, "selection autocmds outlived the session")

-- --------------------------------------------------------------- restart ---
-- A stop that did not clean up would make this fail, which is the whole of c-5.

local restart_output = vim.fn.execute("CodriverStart")
local restarted = server.get_status()

harness.expect_eq(restarted.running, true, "a start after a stop did not bring the server back")
harness.expect(type(restarted.port) == "number", "the restarted server reports no port")
harness.expect_contains(restart_output, tostring(restarted.port), "the restart output does not name its port")
harness.expect_eq(#harness.lock_files(), 1, "the restart did not leave exactly one lockfile: " .. lock_names())
-- Named for the port that is actually listening. Not asserted to *differ* from
-- the first: the vendored allocator picks a random offset across the range and
-- may legitimately hand back the port it just released.
harness.expect_eq(lock_names(), ("%d.lock"):format(restarted.port), "the lockfile is not named for the new port")

harness.expect(pcall(vim.cmd, "CodriverStop"), "the second CodriverStop threw")
harness.expect_eq(#harness.lock_files(), 0, "lockfiles left behind: " .. lock_names())

-- ------------------------------------------------- stop with nothing running ---

local idle_stop_ok, idle_stop_err = pcall(vim.cmd, "CodriverStop")
harness.expect(idle_stop_ok, "stopping with nothing running raised: %s", tostring(idle_stop_err))
harness.expect_contains(last_notified().msg, "no session", "stopping nothing does not say so")
harness.expect(
  last_notified().level ~= vim.log.levels.ERROR,
  "stopping nothing was reported at error level: " .. last_notified().msg
)
harness.expect_eq(#harness.lock_files(), 0, "stopping nothing touched the lock dir: " .. lock_names())

-- ----------------------------------------------------------- failed bind ---
-- A lockfile advertises a port to Claude. One written for a server that never
-- came up points Claude at nothing.

local blocker = assert(vim.uv.new_tcp())
assert(blocker:bind("127.0.0.1", 0))
local blocked_port = blocker:getsockname().port
assert(blocker:listen(128, function() end))

setup({ port_range = { min = blocked_port, max = blocked_port } })

-- Through `pcall`, because an error-level `vim.notify` reaches the user as an
-- error message and `execute()` turns that into a raised Lua error. Either way
-- the text the user sees is what is asserted below.
local _, failed_output = pcall(vim.fn.execute, "CodriverStart")
local failed_status = server.get_status()
local failed_locks = lock_names()
local failed_notification = last_notified()

blocker:close()

harness.expect_eq(failed_status.running, false, "a server that could not bind reports as listening")
harness.expect_eq(failed_locks, "(none)", "a failed bind left a lockfile: " .. failed_locks)
harness.expect_contains(
  tostring(failed_output),
  tostring(blocked_port),
  "the failure does not name the exhausted port range"
)
harness.expect_contains(
  failed_notification.msg,
  tostring(blocked_port),
  "the notified failure does not name the exhausted port range"
)
harness.expect_eq(failed_notification.level, vim.log.levels.ERROR, "a failed bind was not reported as an error")

harness.ok("start reports its port, restart is idempotent, stop cleans up, and a failed bind leaves no lockfile")
