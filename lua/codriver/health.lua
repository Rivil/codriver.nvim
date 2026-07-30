---@brief The detailed answer to "why isn't this working?" — `:checkhealth codriver`.
---
--- Health is where Neovim users already look when something is wrong, so this
--- is where the long form lives: toolchain, terminal provider, and the session
--- broken out into the things that can independently be false. `:CodriverStatus`
--- is the one-line, in-flow counterpart — different moment, different surface.
---
--- The session lines are built from `codriver.session.snapshot()`, not from the
--- vendored report. The vendored one asks `is_claude_connected()`, which falls
--- back to `client_count > 0` when it has no client detail — so a bare TCP
--- connection, or a stale count, reads as Claude. Listening and connected are
--- two questions and this file answers them on two lines (c-4).
---
--- Neovim resolves `:checkhealth <name>` by globbing `lua/**/<name>/health.lua`,
--- matching on the *directory*. So this file has to sit at exactly
--- `lua/codriver/health.lua` — and it is why the vendored tree's own health
--- module is renamed to `health_vendored.lua` by scripts/vendor-sync.sh, so that
--- installing codriver does not inject a section into a real claudecode.nvim's
--- report.

local M = {}

local health = vim.health
local start = health.start
local ok = health.ok
local warn = health.warn
local error_ = health.error
local info = health.info

---Codriver's Neovim floor.
---
---Higher than the vendored layer's 0.8.0 on purpose: this file calls
---`vim.health.start` and friends without the pre-0.10 `report_*` fallback, and
---the pinned toolchain (see mise.toml) is 0.12.3.
local NVIM_FLOOR = "0.10.0"

---First token of a command string — the bit that has to be executable.
---@param cmd string
---@return string
local function executable_of(cmd)
  return cmd:match("^(%S+)") or cmd
end

local function check_neovim()
  if vim.fn.has("nvim-" .. NVIM_FLOOR) == 1 then
    ok("Neovim >= " .. NVIM_FLOOR)
  else
    error_("Neovim >= " .. NVIM_FLOOR .. " is required")
  end
end

---@param config table The resolved vendored config
local function check_cli(config)
  local terminal_cmd = config.terminal_cmd
  local cmd = (type(terminal_cmd) == "string" and terminal_cmd ~= "") and terminal_cmd or "claude"
  local exe = executable_of(cmd)

  if vim.fn.executable(exe) ~= 1 then
    error_(("Claude CLI not found: '%s' is not executable"):format(exe), {
      "Install Claude Code: https://docs.anthropic.com/en/docs/claude-code",
      "Or set `claudecode.terminal_cmd` in setup() to the full path of the CLI",
    })
    return
  end

  ok(("Claude CLI: %s (%s)"):format(exe, vim.fn.exepath(exe)))
end

---@param config table The resolved vendored config
local function check_terminal_provider(config)
  local provider = config.terminal and config.terminal.provider or "auto"

  if type(provider) == "table" then
    info("Terminal provider: custom (table)")
    return
  end

  if provider == "auto" or provider == "snacks" then
    if pcall(require, "snacks") then
      ok(("Terminal provider '%s': snacks.nvim available"):format(provider))
    elseif provider == "snacks" then
      error_("Terminal provider 'snacks' is configured but snacks.nvim is not installed")
    else
      ok("Terminal provider 'auto': snacks.nvim not installed, falling back to the native terminal")
    end
    return
  end

  ok(("Terminal provider: %s"):format(provider))
end

---The three things that can independently be false about a session.
---@param snapshot CodriverStatusSnapshot|table
local function check_session(snapshot)
  if not snapshot.listening then
    warn("No session: the WebSocket server is not listening", {
      "Open one with :CodriverStart",
      "Nothing listens until you ask it to — see the `auto_start` option to open a session on launch",
    })
    return
  end

  ok(("Listening on port %d"):format(snapshot.port))

  -- Separate from the port line because it fails separately: the server can be
  -- perfectly healthy while Claude has nothing to discover it by.
  if snapshot.lockfile then
    ok("Lockfile: " .. snapshot.lockfile)
  else
    error_("Lockfile missing: " .. tostring(snapshot.lockfile_path), {
      "Claude discovers this Neovim instance through the lockfile",
      "Restart the session with :CodriverStop then :CodriverStart",
    })
  end

  -- And this is the line the vendored report cannot give you. A listening
  -- server with nobody attached is the state you are in when a send silently
  -- queues, and it must never render as OK (c-4).
  if snapshot.connected then
    local count = snapshot.client_count or 1
    ok(("Claude attached (%d client%s)"):format(count, count == 1 and "" or "s"))
  else
    warn("Waiting for Claude: no client has completed the WebSocket handshake", {
      "Launch one with :Codriver",
      "A client that has connected but not upgraded is not counted here — listening is not attached",
    })
  end
end

---Render `:checkhealth codriver`.
function M.check()
  start("codriver.nvim")

  check_neovim()

  local codriver_ok, codriver = pcall(require, "codriver")
  if not codriver_ok then
    error_("Could not load the codriver module: " .. tostring(codriver))
    return
  end
  ok("codriver.nvim " .. codriver.version:string())

  local vendor_ok, vendor = pcall(require, "codriver.vendor.claudecode")
  if not vendor_ok then
    error_("Could not load the vendored protocol layer: " .. tostring(vendor))
    return
  end

  if not (vendor.state and vendor.state.initialized) then
    error_("setup() has not been called", {
      'Call require("codriver").setup({}) — or hand the same table to your plugin manager\'s `opts`',
    })
    return
  end

  local config = vendor.state.config or {}
  check_cli(config)
  check_terminal_provider(config)

  check_session(require("codriver.session").snapshot())
end

return M
