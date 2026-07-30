---@brief Who is holding the keyboard.
---
--- Codriver's whole premise is that this is explicit state rather than a thing
--- the model is politely asked to respect. This module owns the state and
--- nothing else: reading it, setting it, and telling you when it changed.
---
--- Actually *enforcing* the role — withdrawing Claude's Edit/Write capability
--- when it is the navigator — is a separate concern that hangs off the change
--- notification. It is deliberately not implemented here yet; see the phase
--- plan. Until it is, `role` is descriptive, not restrictive, and calling it
--- an enforcement boundary would be a lie.

local M = {}

---@alias CodriverRole "navigator"|"driver"

---The human drives by default. Claude starts as the navigator: watching and
---advising, not writing. Anything else would contradict the point of the plugin.
---@type CodriverRole
local current = "navigator"

---@type table<integer, fun(new_role: CodriverRole, previous: CodriverRole)>
local listeners = {}
local next_listener_id = 1

---Which role Claude currently holds.
---@return CodriverRole
function M.get()
  return current
end

---Whether Claude is currently the navigator (advising, not writing).
---@return boolean
function M.is_navigator()
  return current == "navigator"
end

---Hand the keyboard over, or take it back.
---
---Setting the role it already holds is a no-op and fires no listeners, so
---callers can be idempotent without guarding.
---@param role CodriverRole
---@return CodriverRole role The role now held
function M.set(role)
  if role ~= "navigator" and role ~= "driver" then
    error(('codriver.role: expected "navigator" or "driver", got %s'):format(vim.inspect(role)), 2)
  end

  if role == current then
    return current
  end

  local previous = current
  current = role

  for _, listener in pairs(listeners) do
    -- One misbehaving listener must not strand the role half-applied, so each
    -- is isolated and its failure reported rather than propagated.
    local ok, err = pcall(listener, current, previous)
    if not ok then
      vim.notify(("codriver.role: listener error: %s"):format(err), vim.log.levels.ERROR)
    end
  end

  return current
end

---Swap navigator <-> driver.
---@return CodriverRole role The role now held
function M.toggle()
  return M.set(current == "navigator" and "driver" or "navigator")
end

---Register a callback fired after every role change.
---@param listener fun(new_role: CodriverRole, previous: CodriverRole)
---@return fun() unsubscribe
function M.on_change(listener)
  local id = next_listener_id
  next_listener_id = next_listener_id + 1
  listeners[id] = listener
  return function()
    listeners[id] = nil
  end
end

---Drop all listeners and return to the default role. For tests.
function M._reset()
  current = "navigator"
  listeners = {}
  next_listener_id = 1
end

return M
