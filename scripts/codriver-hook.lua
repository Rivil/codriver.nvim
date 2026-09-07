-- codriver's Claude Code PreToolUse hook. Registered by
-- codriver.hook.claude_settings.install() as:
--
--   nvim --clean -l scripts/codriver-hook.lua
--
-- `--clean` means no user config, no runtimepath, no mise/luarocks on PATH —
-- this script is the only thing that runs. codriver's own lua/ modules are
-- not reachable through the normal plugin runtimepath discovery, so
-- package.path is derived from this script's own location before anything
-- is required.
--
-- Contract with Claude Code: an allowed call prints nothing and exits 0. A
-- denied call prints exactly one JSON document on stdout and exits 0 — never
-- a bare non-zero exit, which Claude Code reads as a non-blocking hook error
-- and lets the tool call through regardless. Every internal failure inside a
-- live session (unparsable stdin, a decision core that raises, ...) becomes
-- that same deny document rather than a crash, so a bug here fails closed,
-- not open.

local script = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local plugin_root = vim.fn.fnamemodify(script, ":p:h:h")
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

-- Mirrors codriver.hook.decision's own indeterminate-role reason: an internal
-- error inside a live session is, from Claude's side, indistinguishable from
-- role state that could not be read, and the refusal_message lock allows no
-- third denial text.
local INDETERMINATE_REASON = "codriver: role could not be determined for this live session — "
  .. "denying by default. This is a harness-level refusal, not retryable."

---@param tool_input table|nil
---@return string|nil
local function target_path(tool_input)
  if type(tool_input) ~= "table" then
    return nil
  end
  return tool_input.file_path or tool_input.notebook_path or tool_input.command
end

---Fire-and-forget the refusal at the live Neovim instance over its RPC
---server address. Never blocks and never raises past this call: a dead or
---missing address must not change, delay, or crash the deny already decided.
---@param tool string|nil
---@param path string|nil
local function notify(tool, path)
  local address = os.getenv("CODRIVER_NVIM_ADDRESS")
  if type(address) ~= "string" or address == "" then
    return
  end
  local ok_chan, chan = pcall(vim.fn.sockconnect, "pipe", address, { rpc = true })
  if not ok_chan or type(chan) ~= "number" or chan == 0 then
    return
  end
  pcall(
    vim.rpcnotify,
    chan,
    "nvim_exec_lua",
    "require('codriver.hook.notify').refused(...)",
    { { tool = tool, path = path } }
  )
end

---Exactly one JSON object on stdout, nothing else — a stray print here would
---make the document unparsable and the deny silently degrades to an allow.
---@param reason string|nil
local function emit_deny(reason)
  io.write(vim.json.encode({
    hookSpecificOutput = {
      hookEventName = "PreToolUse",
      permissionDecision = "deny",
      permissionDecisionReason = reason,
    },
  }))
end

local ok_state, state = pcall(require, "codriver.hook.state")

local probe = { live = false }
if ok_state then
  local ok_probe, probed = pcall(state.probe, { CODRIVER_STATE_FILE = os.getenv("CODRIVER_STATE_FILE") })
  if ok_probe and type(probed) == "table" then
    probe = probed
  end
end

---Read stdin, decode Claude Code's hook payload, and run the pure decision
---core. Isolated in its own function so the pcall below can fall back to
---`probe` (already known-good) without losing it to the same failure.
---@return { permission: "allow"|"deny", reason: string? }, string?, table?
local function decide()
  local raw = io.read("*a") or ""
  local ok_decode, decoded = pcall(vim.json.decode, raw)
  local tool_name, tool_input
  if ok_decode and type(decoded) == "table" then
    tool_name = decoded.tool_name
    tool_input = decoded.tool_input
  end

  local decision = require("codriver.hook.decision")
  local result = decision.decide({ tool = tool_name, tool_input = tool_input }, probe)
  return result, tool_name, tool_input
end

local ok, result, tool_name, tool_input = pcall(decide)
if not ok then
  result = probe.live and { permission = "deny", reason = INDETERMINATE_REASON } or { permission = "allow" }
end

if result.permission == "deny" then
  emit_deny(result.reason)
  notify(tool_name, target_path(tool_input))
end

os.exit(0, true)
