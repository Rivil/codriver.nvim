---@brief Re-exporting the vendored command surface under `:Codriver*`.
---
--- Codriver exposes one namespace. The vendored layer wants to register fifteen
--- `:ClaudeCode*` commands during its `setup()`, and a user may well have the
--- real claudecode.nvim installed alongside — so those registrations are
--- intercepted rather than cleaned up afterwards. Deleting them afterwards
--- would delete the *other* plugin's commands, which is the collision this
--- exists to prevent.
---
--- Interception also means the surface grows deliberately: a vendored command
--- that appears in an upstream re-sync has no `:Codriver*` name, and
--- `register()` says so instead of quietly dropping it.
---
--- The `api` table is an argument rather than a hardcoded `vim.api` so the shim
--- can be driven by a fake under bare LuaJIT. It is patched *in place*, because
--- that is the only way to intercept a vendored call site that reaches for
--- `vim.api.nvim_create_user_command` directly.

local M = {}

---Vendored command name -> the `:Codriver*` name it is re-exported as.
---
---Spelled out rather than derived. This table is the command surface, and
---`register()` checks the vendored layer against it on every setup — an
---upstream re-sync that adds or renames a command has to be answered here.
---@type table<string, string>
M.map = {
  ClaudeCode = "Codriver",
  ClaudeCodeFocus = "CodriverFocus",
  ClaudeCodeOpen = "CodriverOpen",
  ClaudeCodeClose = "CodriverClose",
  ClaudeCodeSend = "CodriverSend",
  ClaudeCodeAdd = "CodriverAdd",
  ClaudeCodeTreeAdd = "CodriverTreeAdd",
  ClaudeCodeSendText = "CodriverSendText",
  ClaudeCodeDiffAccept = "CodriverDiffAccept",
  ClaudeCodeDiffDeny = "CodriverDiffDeny",
  ClaudeCodeCloseAllDiffs = "CodriverCloseAllDiffs",
  ClaudeCodeSelectModel = "CodriverSelectModel",
  ClaudeCodeStart = "CodriverStart",
  ClaudeCodeStop = "CodriverStop",
  ClaudeCodeStatus = "CodriverStatus",
}

---Augroups renamed while the shim is installed.
---
---Exactly one, and for one reason: the vendored `ClaudeCodeShutdown` group is
---created with `clear = true`, so if a real claudecode.nvim is also installed,
---codriver's setup would clear that plugin's VimLeavePre handler and leave it
---to leak its lockfile on exit.
---
---Every other vendored group is deliberately left alone. `ClaudeCodeSelection`
---above all: `selection.disable()` clears it by literal name, so a renamed
---group would strand its autocmds and make `stop()` throw.
---@type table<string, string>
M.augroup_map = {
  ClaudeCodeShutdown = "CodriverShutdown",
}

---@class CodriverCapturedCommand
---@field name string The vendored command name
---@field handler function|string What the command runs
---@field opts table The options it was registered with (range, nargs, bang, ...)

---Run `fn` with command registration intercepted, and return what it tried to
---register.
---
---Scope this to the vendored `setup()` and nothing else. It must never wrap
---`start()` or `stop()`: with `auto_start` forced off (see codriver.config)
---`setup()` does not reach the selection or diff machinery whose augroups this
---shim deliberately does not rename.
---@param fn fun()
---@param api table|nil defaults to `vim.api`
---@return CodriverCapturedCommand[] captured
function M.capture(fn, api)
  api = api or vim.api

  local original_command = api.nvim_create_user_command
  local original_augroup = api.nvim_create_augroup

  ---@type CodriverCapturedCommand[]
  local captured = {}

  api.nvim_create_user_command = function(name, handler, opts)
    table.insert(captured, { name = name, handler = handler, opts = opts or {} })
  end

  api.nvim_create_augroup = function(name, opts)
    return original_augroup(M.augroup_map[name] or name, opts)
  end

  local ok, err = pcall(fn)

  -- Restored before the error is re-raised. A leaked shim would swallow the
  -- user commands of every plugin that loads after this one.
  api.nvim_create_user_command = original_command
  api.nvim_create_augroup = original_augroup

  if not ok then
    error(err, 0)
  end

  return captured
end

---Register captured commands under their `:Codriver*` names.
---
---`decorate` is how a caller substitutes or wraps a handler — returning a
---replacement entry, the entry it was given, or nil to skip the command
---entirely.
---@param captured CodriverCapturedCommand[]
---@param api table|nil defaults to `vim.api`
---@param decorate nil|fun(name: string, entry: CodriverCapturedCommand): CodriverCapturedCommand|nil
---@return string[] registered The `:Codriver*` names now registered
function M.register(captured, api, decorate)
  api = api or vim.api

  local registered = {}
  for _, entry in ipairs(captured) do
    local target = M.map[entry.name]
    if not target then
      error(
        ("codriver.commands: the vendored layer registered %s, which has no :Codriver* name. "):format(entry.name)
          .. "A vendor re-sync added or renamed a command — add it to codriver.commands.map.",
        2
      )
    end

    local final = entry
    if decorate then
      final = decorate(entry.name, entry)
    end

    if final then
      api.nvim_create_user_command(target, final.handler, final.opts or {})
      table.insert(registered, target)
    end
  end

  return registered
end

return M
