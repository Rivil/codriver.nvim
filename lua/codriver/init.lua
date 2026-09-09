---@brief codriver.nvim — Claude Code as a navigator, not an author.
---
--- This is the wrapper layer. The Claude Code IDE protocol (WebSocket server,
--- lockfile, MCP tools) is vendored from coder/claudecode.nvim under
--- `codriver.vendor.claudecode` and is not modified — see VENDOR.md. Codriver
--- behaviour belongs here, never in there.
---
--- `setup()` is where the wrapper's four pieces meet: options are split
--- (codriver.config), the vendored setup runs with its command registration
--- intercepted (codriver.commands), the resulting surface is re-exported under
--- `:Codriver*`, and the session is opened only if the user asked for it
--- (codriver.session). Turn-taking enforcement, ambient review on save, and
--- dross task binding are not implemented yet.

local M = {}

M.version = {
  major = 0,
  minor = 1,
  patch = 5,
}

---@return string
function M.version:string()
  return ("%d.%d.%d"):format(self.major, self.minor, self.patch)
end

M.role = require("codriver.role")

local commands = require("codriver.commands")
local config = require("codriver.config")
local session = require("codriver.session")
local state = require("codriver.hook.state")
local status = require("codriver.status")
local winbar = require("codriver.winbar")

---Guards the role listener against a second `setup()` call registering a
---second copy of it. The shutdown autocmd needs no such guard — the vendored
---setup recreates its augroup with `clear = true` on every call, which would
---wipe out an autocmd attached only once, so that one is (harmlessly)
---re-attached every time instead. Everything else in `setup()` — resolving
---options, capturing and re-registering commands — is already safe to repeat,
---per the existing "survives being set up twice" test.
local enforcement_hooked = false

---Reached at call time so that merely requiring codriver does not spin up the
---protocol layer — and so a spec can put a fake in `package.loaded`.
---@return table
local function vendor()
  return require("codriver.vendor.claudecode")
end

---@param message string
---@param level integer|nil defaults to INFO
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

---Vendored commands whose handler opens a Claude terminal.
---
---Each one needs a listening server *before* the terminal comes up: the
---vendored terminal builds the CLI's environment as it opens, and with no
---server there is no `CLAUDE_CODE_SSE_PORT` to put in it — the user gets a
---Claude that can never connect back (c-2).
---
---`ClaudeCodeSendText` and `ClaudeCodeClose` are deliberately absent: they act
---on a terminal that already exists, so there is nothing to pre-flight.
---@type table<string, true>
local PREFLIGHT = {
  ClaudeCode = true,
  ClaudeCodeFocus = true,
  ClaudeCodeOpen = true,
  ClaudeCodeSelectModel = true,
}

---Open a session, and say where it is.
local function start_command()
  local result = session.start()

  if result.error then
    notify("codriver: could not start a session — " .. result.error, vim.log.levels.ERROR)
    return
  end

  -- The indicator exists only while a session does (c-4, no_session_lifecycle):
  -- shown here, on the one path that actually brings a session up.
  winbar.show()

  -- Reported through the same formatter as `:CodriverStatus`, so "started" and
  -- "already running" answer the question the user actually asked — which port,
  -- and is Claude on it — in one shape rather than two.
  local line = status.describe(session.snapshot())
  if result.already_running then
    line = line .. " (session already running)"
  end
  if result.terminal_error then
    line = line .. " (no terminal: " .. result.terminal_error .. ")"
  end

  notify(line)
end

---Shut the session down.
local function stop_command()
  local result = session.stop()

  if result.already_stopped then
    -- Not an error: stopping what is already stopped is the state you wanted.
    notify("codriver: no session to stop")
    return
  end

  if result.error then
    notify("codriver: could not stop the session — " .. result.error, vim.log.levels.ERROR)
    return
  end

  -- Cleared only on a genuine stop — not above, where the server never came
  -- down and the indicator is still describing a real session.
  winbar.hide()

  notify(result.port and ("codriver: session on port %d stopped"):format(result.port) or "codriver: session stopped")
end

---Answer "is this thing on?" in one line.
local function status_command()
  notify(status.describe(session.snapshot()))
end

---Hand the keyboard to Claude.
local function handover_command()
  M.role.set("driver")
  notify("codriver: Claude is driving")
end

---Take the keyboard back.
local function takeback_command()
  M.role.set("navigator")
  notify("codriver: you're driving")
end

---Vendored commands codriver answers itself rather than re-exporting.
---
---The vendored trio print through the vendored logger and conflate listening
---with connected; these route through `codriver.session` and
---`codriver.status` instead (c-4).
---@type table<string, { handler: fun(), desc: string }>
local OWNED = {
  ClaudeCodeStart = { handler = start_command, desc = "Open a codriver session and a terminal to talk to it" },
  ClaudeCodeStop = { handler = stop_command, desc = "Shut the codriver session down" },
  ClaudeCodeStatus = {
    handler = status_command,
    desc = "Report whether codriver is listening and whether Claude is attached",
  },
}

---Wrap a terminal-opening handler so the server is up before it runs.
---
---`ensure_server()`, never `start()`: the vendored handler owns the terminal,
---and a wrapper that opened one too would leave `:Codriver` from cold showing
---two terminals — or one it immediately toggles away.
---@param handler function
---@return fun(args: table)
local function with_server(handler)
  return function(args)
    local result = session.ensure_server()
    if result.error then
      notify("codriver: could not start a session — " .. result.error, vim.log.levels.ERROR)
      return
    end
    return handler(args)
  end
end

---Decide what each captured vendored command becomes under its `:Codriver*`
---name.
---@param name string The vendored command name
---@param entry CodriverCapturedCommand
---@return CodriverCapturedCommand
local function decorate(name, entry)
  local owned = OWNED[name]
  if owned then
    return { name = name, handler = owned.handler, opts = { desc = owned.desc } }
  end

  -- Bound to a local so the `function|string` handler type narrows: a command
  -- registered as a string of Vimscript has nothing to wrap.
  local handler = entry.handler
  if PREFLIGHT[name] and type(handler) == "function" then
    return { name = name, handler = with_server(handler), opts = entry.opts }
  end

  return entry
end

---Set up codriver.
---
---Codriver's own options go at the top level, the vendored layer's under
---`claudecode` — see codriver.config.
---@param opts table|nil
---@return table module
function M.setup(opts)
  local first_setup = not enforcement_hooked
  enforcement_hooked = true

  -- Established before config.resolve() is called, so the channel it injects
  -- into the vendored env carries real values rather than nil (c-6). A headless
  -- `nvim --clean -l` has an empty v:servername, which is exactly the case that
  -- must not fall through to a missing address — every hook-process refusal
  -- would have nowhere to notify.
  local address = vim.v.servername
  if address == nil or address == "" then
    address = vim.fn.serverstart()
  end

  local resolved = config.resolve(opts, { state_file = state.path(), nvim_address = address })

  -- Exposed on the module itself (not only the state file) so health.lua can
  -- read the resolved bash_allow directly — the state file is a channel to the
  -- hook subprocess, not the only place setup()'s output should live.
  M.config = resolved.codriver

  -- A `setup()` re-run or plugin hot-reload resets this Lua module's
  -- in-memory role back to the "navigator" default even when a driver session
  -- is still live on disk. Restore from this pid's own record first, before
  -- anything below republishes — a reload must never silently end an active
  -- handover the human didn't ask to end (c-4).
  local existing = state.read(state.path())
  if existing and existing.role and existing.role ~= M.role.get() then
    M.role.set(existing.role)
  end

  ---Publish the role, keeping the resolved test_command and bash_allow that
  ---were here before — the on_change republish must not drop a field it is not
  ---changing, or c-5's allowlisted test command (or a bash_allow addition)
  ---silently stops working after the first handover.
  ---@param role string
  local function publish_role(role)
    state.publish({
      role = role,
      test_command = resolved.codriver.test_command,
      bash_allow = resolved.codriver.bash_allow,
    })
  end

  -- Before the vendored setup runs, so the state file is already a readable
  -- navigator record by the time Claude could reach it (c-6).
  publish_role(M.role.get())

  if first_setup then
    M.role.on_change(publish_role)
  end

  -- The vendored setup wants to register fifteen `:ClaudeCode*` commands. They
  -- are intercepted rather than deleted afterwards, because deleting them would
  -- delete the real claudecode.nvim's commands if the user has it installed
  -- (c-6). Scoped to this call and nothing else: `auto_start` is forced off in
  -- config.resolve, so nothing inside here reaches the selection or diff
  -- augroups the shim deliberately leaves alone.
  local captured = commands.capture(function()
    vendor().setup(resolved.claudecode)
  end)

  commands.register(captured, vim.api, decorate)

  -- Pure codriver commands, not sourced from the vendored capture above: no
  -- OWNED entry and no PREFLIGHT wrapping applies to them.
  vim.api.nvim_create_user_command("CodriverHandover", handover_command, { desc = "Hand the keyboard to Claude" })
  vim.api.nvim_create_user_command("CodriverTakeback", takeback_command, { desc = "Take the keyboard back from Claude" })

  -- Not guarded by first_setup: the vendored setup above just (re-)created the
  -- shutdown augroup with `clear = true`, which wipes any autocmd a previous
  -- call attached to it. Re-attaching every time is correct rather than
  -- redundant — it has to come after the vendored setup either way, since
  -- attaching to a group by name before it exists raises.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = "CodriverShutdown",
    callback = function()
      state.clear()
      winbar.hide()
    end,
    desc = "Clear codriver's session role record when Neovim exits",
  })

  -- Last, and only on request. Everything the session might notify about now
  -- has a `:Codriver*` command behind it.
  if resolved.codriver.auto_start then
    start_command()
  end

  return M
end

---Version of codriver itself, and of the vendored protocol layer it wraps.
---@return { codriver: string, claudecode: string }
function M.get_version()
  return {
    codriver = M.version:string(),
    claudecode = vendor().get_version().version,
  }
end

return M
