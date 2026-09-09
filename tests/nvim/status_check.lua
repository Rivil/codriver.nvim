-- Status surface — run under real Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/status_check.lua
--
-- Drives the two surfaces c-4 is a claim about, through the commands a user
-- actually types: `:CodriverStatus` for the one-line in-flow answer, and
-- `:checkhealth codriver` for the detailed one. Both are exercised as commands
-- rather than as module calls — `:CodriverStatus` is codriver-owned rather than
-- re-exported (see the OWNED table in codriver.init), and a unit test of
-- `status.describe` would pass happily while the command still routed through
-- the vendored handler that conflates listening with connected.
--
-- The genuinely-connected state needs the `claude` CLI completing a real
-- WebSocket upgrade, which nothing here can do. The closest headless proxy is to
-- fake it at the snapshot boundary: `codriver.session.snapshot()` decides
-- `connected` by scanning `state.server.get_status().clients` for a completed
-- handshake, so patching `get_status` to report one drives the real snapshot,
-- the real formatter and the real command. (The task described this as stubbing
-- the vendored `is_claude_connected`; the snapshot deliberately does not call
-- that function — see the comment in codriver.session — so stubbing it would
-- fake nothing.) t-5 covers the unstubbed empty-clients fallback and t-9 proves
-- the CLI is launched pointing at the right port.
--
-- The session is brought up with `session.ensure_server()` rather than
-- `:CodriverStart`, which would also launch a real `claude` terminal in a
-- headless process.
--
-- Harness assertions are fatal, so every observation is gathered and the session
-- torn down before anything is asserted.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

---Run `:checkhealth codriver` and return the rendered report.
---@return string
local function report()
  vim.cmd("checkhealth codriver")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.cmd("bwipeout!")
  return text
end

---Run `:CodriverStatus` and return what it reported.
---@return string
local function status_line()
  return vim.fn.execute("CodriverStatus")
end

require("codriver").setup({})

local claudecode = require("codriver.vendor.claudecode")
local session = require("codriver.session")

-- ---------------------------------------------------------------- gather ---

-- Cold, before anything has started. A status query is a question, not an
-- action: it must not bring a server up or write a lockfile as a side effect of
-- being asked.
local cold_line = status_line()
local cold_server = (claudecode.state or {}).server
local cold_locks = harness.lock_files()
local cold_report = report()

local started = session.ensure_server()
local snapshot = session.snapshot()
local port, lock_path = snapshot.port, snapshot.lockfile_path

-- Listening, nothing attached — the state in which a send silently queues.
local waiting_line = status_line()

-- Attached. Patched on the table `session.snapshot()` actually reaches for, so
-- the whole path below the fake is the real one.
local real_get_status = claudecode.state.server.get_status
claudecode.state.server.get_status = function(...)
  local status = real_get_status(...) or {}
  status.clients = { { handshake_complete = true } }
  status.client_count = 1
  return status
end

local attached_line, attached_report
local attached_ok, attached_err = pcall(function()
  attached_line = status_line()
  attached_report = report()
end)

claudecode.state.server.get_status = real_get_status

local stopped = session.stop()
local leftover = harness.lock_files()

-- ---------------------------------------------------------------- assert ---

harness.expect(attached_ok, "the connected-state surfaces raised: %s", tostring(attached_err))
harness.expect(started.started, "ensure_server() did not bring the server up: %s", tostring(started.error))
harness.expect(type(port) == "number", "no port after ensure_server()")
harness.expect(type(lock_path) == "string", "snapshot gave no lockfile path")
harness.expect(stopped.stopped, "stop() failed: %s", tostring(stopped.error))
harness.expect_eq(#leftover, 0, "lockfiles left behind after stop")

-- ------------------------------------------------ :CodriverStatus is a query ---

harness.expect_contains(cold_line, "no session", "a cold :CodriverStatus does not report the absence of a session")
harness.expect(cold_server == nil, "asking for status started a server")
harness.expect_eq(#cold_locks, 0, "asking for status wrote a lockfile: " .. table.concat(cold_locks, ", "))

-- -------------------------------------------- listening is not attached (c-4) ---

harness.expect_contains(waiting_line, ("port %d"):format(port), "the status line does not name the live port")
harness.expect_contains(waiting_line, "waiting for Claude", "a listening server with nothing attached must say so")
harness.expect_not_contains(waiting_line, "Claude attached", "an unattached session is reporting as attached")

harness.expect_contains(attached_line, "Claude attached", "an attached session does not say so")
harness.expect_not_contains(
  attached_line,
  "waiting for Claude",
  "the two states are not distinguishable — an attached session still reads as waiting"
)
harness.expect_contains(attached_line, ("port %d"):format(port), "the attached status line dropped the port")
harness.expect_not_contains(attached_line, "lockfile missing", "the lockfile is present and should not be flagged")

-- --------------------------------------------------- the detailed surface ---

harness.expect_contains(
  attached_report,
  ("Listening on port %d"):format(port),
  "the report does not name the live port"
)
harness.expect_contains(attached_report, lock_path, "the report does not name the lockfile path")
harness.expect(
  lock_path:find(harness.lock_dir, 1, true) == 1,
  "the lockfile path %s is not under the harness lock dir %s",
  lock_path,
  harness.lock_dir
)
harness.expect_contains(attached_report, "Claude attached (1 client)", "the report gives no connected-client count")
harness.expect_contains(attached_report, "Claude CLI", "the report says nothing about the Claude CLI")

-- Advice may only name commands codriver registers. The cold report is where
-- the start advice lives; neither report may reach for the vendored namespace.
harness.expect_contains(cold_report, ":CodriverStart", "the no-session report does not say how to open one")
harness.expect_not_contains(cold_report, "ClaudeCodeStart", "the report advises a command codriver does not register")
harness.expect_not_contains(
  attached_report,
  "ClaudeCodeStart",
  "the report advises a command codriver does not register"
)

harness.ok(":CodriverStatus and :checkhealth codriver tell listening and attached apart")
