-- Claude-terminal environment — run under real Neovim by `mise run test-nvim`,
-- or alone:
--
--   nvim --clean --headless -l tests/nvim/terminal_env_check.lua
--
-- c-2 is a claim about a process nobody here can start: what `claude` is
-- actually launched with. So this drives the real commands against a custom
-- table provider — the vendored provider contract, seven functions — and
-- inspects the `(cmd_string, env_table, effective_config)` the vendored layer
-- hands it. That table is the CLI's environment; asserting on it is as close to
-- the launched process as a headless check can get.
--
-- Two scenarios, and the order matters. The cold `:Codriver` runs *first*,
-- while "no server has ever been started in this process" is still true — that
-- is the state the pre-flight guard exists for, and the state in which a second
-- terminal would show up. `:CodriverStart` follows, after a stop.
--
-- Each recorded call also carries whether the server was listening *at the
-- moment it was made*. The port key being present afterwards is not the
-- contract; the sequence is. A terminal opened first and a server started
-- second would still leave a live port in `get_status()`, and a Claude that
-- never got one.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local codriver = require("codriver")
local server = require("codriver.vendor.claudecode.server.init")
local session = require("codriver.session")

---Every provider call that puts something on screen, in order.
---@type { fn: string, cmd: any, env: any, listening: boolean }[]
local calls = {}

---Whether the session is listening right now.
---
---Through `pcall` because `provider.setup` is called from inside the vendored
---`setup()`, before this process has a session at all — a snapshot that raised
---there would fail the check for the wrong reason.
---@return boolean
local function listening_now()
  local ok, snapshot = pcall(session.snapshot)
  return ok and snapshot.listening == true
end

---@param name string
---@return fun(cmd: any, env: any, config: any)
local function record(name)
  return function(cmd, env, config)
    table.insert(calls, { fn = name, cmd = cmd, env = env, config = config, listening = listening_now() })
  end
end

---A provider that launches nothing and remembers everything. `is_available`
---and `get_active_bufnr` are queries the vendored layer makes on its way to a
---decision, not terminals appearing, so they are deliberately not recorded.
local provider = {
  setup = record("setup"),
  open = record("open"),
  close = record("close"),
  simple_toggle = record("simple_toggle"),
  focus_toggle = record("focus_toggle"),
  get_active_bufnr = function()
    return nil
  end,
  is_available = function()
    return true
  end,
}

codriver.setup({ claudecode = { terminal = { provider = provider } } })

local function reset()
  calls = {}
end

---The calls that would have put a terminal on screen.
---@return { fn: string, cmd: any, env: any, listening: boolean }[]
local function terminals()
  local out = {}
  for _, call in ipairs(calls) do
    if call.fn == "open" or call.fn == "simple_toggle" or call.fn == "focus_toggle" then
      table.insert(out, call)
    end
  end
  return out
end

---@return string
local function summary()
  local names = {}
  for _, call in ipairs(calls) do
    table.insert(names, call.fn)
  end
  return #names > 0 and table.concat(names, ", ") or "(none)"
end

---Assert the environment a Claude launched by `call` would inherit.
---@param call { cmd: any, env: any }
---@param port integer
---@param what string
local function expect_launch_env(call, port, what)
  local env = type(call.env) == "table" and call.env or {}

  harness.expect_eq(
    env.CLAUDE_CODE_SSE_PORT,
    tostring(port),
    what .. ": the CLI was given no live port to connect back to"
  )
  harness.expect_eq(env.ENABLE_IDE_INTEGRATION, "true", what .. ": IDE integration was not enabled for the CLI")
  harness.expect_eq(
    env.FORCE_CODE_TERMINAL,
    "true",
    what .. ": the CLI was not told it is running in an editor terminal"
  )

  -- Issue #70 upstream: Claude honours http_proxy/all_proxy, and without a
  -- loopback exclusion it tunnels its own ws://127.0.0.1 connection through the
  -- proxy and never completes the handshake. Present here only because the
  -- wrapper routes through the vendored env builder rather than assembling a
  -- table of its own.
  harness.expect_contains(env.no_proxy, "127.0.0.1", what .. ": no_proxy does not exclude the loopback address")
  harness.expect_contains(env.NO_PROXY, "127.0.0.1", what .. ": NO_PROXY does not exclude the loopback address")

  local token = type(call.cmd) == "string" and call.cmd:match("^%S+") or nil
  harness.expect_eq(token, "claude", what .. ": the launch command drifted (cmd = " .. tostring(call.cmd) .. ")")
end

-- --------------------------------------------------- :Codriver, from cold ---
-- The pre-flight guard's whole job: bring the server up, and leave the terminal
-- to the vendored handler. A guard that called `session.start()` instead would
-- open one terminal here and toggle a second one immediately after.

harness.expect_eq(server.get_status().running, false, "a session was already live before the cold :Codriver")

reset()
vim.cmd("Codriver")

local cold = terminals()
local cold_status = server.get_status()

harness.expect_eq(cold_status.running, true, "a cold :Codriver did not bring the server up first")
harness.expect_eq(#cold, 1, ("a cold :Codriver produced %d terminals, not one: %s"):format(#cold, summary()))
harness.expect(
  cold[1].listening,
  "the terminal came up before the server was listening — the pre-flight guard did not run first"
)
expect_launch_env(cold[1], cold_status.port, "cold :Codriver")

harness.expect(pcall(vim.cmd, "CodriverStop"), "CodriverStop threw after the cold :Codriver")
harness.expect_eq(server.get_status().running, false, "CodriverStop left the server up")

-- ------------------------------------------------------------ :CodriverStart ---
-- Server first, terminal second — the ordering `codriver.session` exists to
-- guarantee.

reset()
vim.cmd("CodriverStart")

local started = server.get_status()
local opened = terminals()

harness.expect_eq(started.running, true, "CodriverStart did not bring the server up")
harness.expect(type(started.port) == "number", "the server reports no port")
harness.expect_eq(#opened, 1, ("CodriverStart produced %d terminals, not one: %s"):format(#opened, summary()))
harness.expect_eq(opened[1].fn, "open", "CodriverStart reached for " .. opened[1].fn .. " rather than open")
harness.expect(
  opened[1].listening,
  "the terminal was opened before the server was listening — the CLI is launched with no port key"
)
expect_launch_env(opened[1], started.port, "CodriverStart")

harness.expect(pcall(vim.cmd, "CodriverStop"), "the second CodriverStop threw")
harness.expect_eq(#harness.lock_files(), 0, "lockfiles left behind")

-- ------------------------------------------- one source for the port value ---
-- The env belongs to the vendored builder. A wrapper module that set
-- CLAUDE_CODE_SSE_PORT itself would be a second source for the same value, free
-- to drift from the port the server actually bound. Prose mentions are expected
-- — there are several, explaining exactly this — so only assignments count.

local offenders = {}
for _, path in ipairs(vim.fn.globpath(harness.repo_root .. "/lua/codriver", "**/*.lua", false, true)) do
  if not path:find("/vendor/", 1, true) then
    for number, line in ipairs(vim.fn.readfile(path)) do
      -- One `=` is an assignment; two is a comparison, which reads the value
      -- rather than inventing one.
      if not line:match("^%s*%-%-") and line:match("CLAUDE_CODE_SSE_PORT[\"']?%]?%s*(==?)") == "=" then
        table.insert(offenders, ("%s:%d"):format(path:sub(#harness.repo_root + 2), number))
      end
    end
  end
end

harness.expect(
  #offenders == 0,
  "a wrapper module assigns CLAUDE_CODE_SSE_PORT itself instead of routing through the vendored env builder: %s",
  table.concat(offenders, ", ")
)

harness.ok("the CLI is launched with the live port after the server is up, and :Codriver from cold opens one terminal")
