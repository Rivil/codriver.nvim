---@brief The one-line answer to "is this thing on?".
---
--- Two questions look like one and are not: whether codriver's server is
--- *listening*, and whether Claude has actually *connected back to it*. A
--- session can sit listening on a port for as long as you like with no Claude
--- attached, and that is the state you are in when a send silently queues.
--- `:CodriverStatus` has to tell those apart in one line, without making you
--- leave the buffer for a health split.
---
--- The detailed report — lockfile path, client count, toolchain — is
--- `:checkhealth codriver`. Different moment, different surface.
---
--- Pure formatting: no `vim.*`, no reaching into the session. It is handed a
--- snapshot and returns a string.

local M = {}

---@class CodriverStatusSnapshot
---@field listening boolean Whether the WebSocket server is up.
---@field port integer|nil The port it is listening on.
---@field connected boolean Whether a client has completed the WebSocket handshake.
---@field client_count integer|nil How many clients are attached.
---@field lockfile string|nil Path of the lockfile advertising this session.

---Phrasings deliberately share no stem. "not connected" and "connected" differ
---by a word that a substring match cannot see, and a status line that reads as
---connected when it is not is precisely the failure this module exists to
---prevent — so the two states are said in different words entirely.
local WAITING = "waiting for Claude"
local ATTACHED = "Claude attached"

---Render a session snapshot as the `:CodriverStatus` line.
---@param snapshot CodriverStatusSnapshot
---@return string
function M.describe(snapshot)
  snapshot = snapshot or {}

  if not snapshot.listening then
    return "codriver: no session — :CodriverStart to open one"
  end

  local where = snapshot.port and ("listening on port %d"):format(snapshot.port) or "listening (port unknown)"

  local who
  if snapshot.connected then
    -- The count comes along only once something is actually attached. Before
    -- the handshake completes it counts TCP connections, which is the number
    -- that makes an unconnected session look connected.
    local count = snapshot.client_count or 1
    who = ("%s (%d client%s)"):format(ATTACHED, count, count == 1 and "" or "s")
  else
    who = WAITING
  end

  local line = ("codriver: %s — %s"):format(where, who)

  -- A listening server whose lockfile has gone is invisible to Claude: the CLI
  -- finds nothing to connect to. Worth the four words here rather than only in
  -- :checkhealth, because it explains why nothing is attaching.
  if snapshot.lockfile == nil or snapshot.lockfile == false then
    line = line .. " (lockfile missing)"
  end

  return line
end

return M
