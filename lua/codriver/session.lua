---@brief Opening, closing and inspecting a codriver session.
---
--- Two entry points, deliberately distinct:
---
---   * `ensure_server()` brings the WebSocket server up and touches nothing
---     else. It is what the terminal-opening commands call as a pre-flight, so
---     that the vendored handler is still the one thing that owns the terminal.
---   * `start()` is `ensure_server()` plus one terminal — the `:CodriverStart`
---     path, where the user is asking for a session *and* somewhere to talk to
---     it.
---
--- Everything returns a structured result rather than printing. Who reports
--- what, and how loudly, belongs to the command layer; a session that notified
--- on its own would talk over `:checkhealth` and over the status line both.
---
--- Selection tracking is conspicuously absent. The vendored `start`/`stop` pair
--- already arm and clear it, both gated on `config.track_selection` — so arming
--- it here would make that opt-out inert and strand `ClaudeCodeSelection`
--- autocmds past `:CodriverStop`. The wrapper's whole job is to leave that
--- alone.

local M = {}

---Reached at call time, never at module load: requiring the vendored layer
---eagerly would spin up the protocol modules just because something asked
---about status, and it would put them beyond the reach of a fake.
---@return table
local function vendor()
  return require("codriver.vendor.claudecode")
end

---@return table|nil
local function vendor_module(name)
  local ok, module = pcall(require, "codriver.vendor.claudecode." .. name)
  if not ok then
    return nil
  end
  return module
end

---@class CodriverStartResult
---@field started boolean Whether this call brought the server up.
---@field already_running boolean Whether a session was already live.
---@field port integer|nil The port the server is listening on.
---@field error string|nil Why the server could not be started.
---@field terminal_error string|nil Why the terminal could not be opened, if it could not.

---Bring the server up if it is not already, without opening a terminal.
---@return CodriverStartResult
function M.ensure_server()
  local claudecode = vendor()
  local state = claudecode.state or {}

  if state.server then
    -- Not an error. Asking for a session you already have should tell you
    -- where it is, not fail (c-1) — and the vendored start() would answer
    -- `false, "Already running"`, which every caller would have to special-case.
    return { started = false, already_running = true, port = state.port }
  end

  -- `false` suppresses the vendored startup notification: the command layer
  -- reports this in codriver's own words.
  local ok, result = claudecode.start(false)

  if not ok then
    return { started = false, already_running = false, error = tostring(result) }
  end

  return {
    started = true,
    already_running = false,
    port = tonumber(result) or (claudecode.state or {}).port,
  }
end

---Open a session and a terminal to talk to it.
---@return CodriverStartResult
function M.start()
  local result = M.ensure_server()

  -- Server first, terminal second. The vendored terminal builds the CLI's
  -- environment when it opens, and with no server listening there is no
  -- CLAUDE_CODE_SSE_PORT to put in it — the terminal would come up running a
  -- Claude that can never connect back (c-2).
  if result.error then
    return result
  end

  local terminal = vendor_module("terminal")
  if not terminal or type(terminal.open) ~= "function" then
    result.terminal_error = "the vendored terminal module is unavailable"
    return result
  end

  local ok, err = pcall(terminal.open, {})
  if not ok then
    -- The server is up and the session is real; the user just has no terminal.
    -- Reported, not raised.
    result.terminal_error = tostring(err)
  end

  return result
end

---@class CodriverStopResult
---@field stopped boolean Whether this call tore a session down.
---@field already_stopped boolean Whether there was nothing to stop.
---@field port integer|nil The port that was torn down.
---@field error string|nil Why the session could not be stopped.

---Shut the session down.
---@return CodriverStopResult
function M.stop()
  local claudecode = vendor()
  local state = claudecode.state or {}

  if not state.server then
    return { stopped = false, already_stopped = true }
  end

  local port = state.port
  local ok, err = claudecode.stop()

  if not ok then
    return { stopped = false, already_stopped = false, port = port, error = tostring(err) }
  end

  -- Deliberately not checked against the lockfile. The vendored stop() warns
  -- and carries on when the lockfile has already gone, and so should this: a
  -- session torn down is torn down, whoever removed the file (c-5).
  return { stopped = true, already_stopped = false, port = port }
end

---Where the lockfile for `port` would be, according to the vendored layer.
---@param port integer|nil
---@return string|nil
local function lockfile_path(port)
  if not port then
    return nil
  end
  local lockfile = vendor_module("lockfile")
  if not lockfile or not lockfile.lock_dir then
    return nil
  end
  return ("%s/%d.lock"):format(lockfile.lock_dir, port)
end

---What the session looks like right now.
---@return CodriverStatusSnapshot|table
function M.snapshot()
  local claudecode = vendor()
  local server = (claudecode.state or {}).server

  if not server or type(server.get_status) ~= "function" then
    return { listening = false, connected = false, client_count = 0 }
  end

  local status = server.get_status() or {}
  local port = status.port or (claudecode.state or {}).port

  -- Computed here rather than delegated to the vendored is_claude_connected(),
  -- which falls back to `client_count > 0` when it has no client info. That
  -- fallback reports a bare TCP connection — or a stale count — as Claude, and
  -- reporting listening as connected is the one thing the status surface must
  -- never do (c-4). A client counts only once it has completed the WebSocket
  -- upgrade.
  local connected = false
  for _, info in ipairs(status.clients or {}) do
    if info.handshake_complete == true then
      connected = true
      break
    end
  end

  local path = lockfile_path(port)
  local present = path ~= nil and vim.fn.filereadable(path) == 1

  return {
    listening = status.running == true,
    port = port,
    connected = connected,
    client_count = status.client_count or 0,
    -- `lockfile` is the file that is actually there; `lockfile_path` is where
    -- it should be either way. A listening server whose lockfile has been
    -- unlinked is invisible to Claude, and naming the absent path is the only
    -- useful thing to say about it.
    lockfile = present and path or nil,
    lockfile_path = path,
  }
end

return M
