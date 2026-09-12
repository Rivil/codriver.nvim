---@brief Coalesces rapid successive `trigger()` calls into a single fire.
---
--- Format-on-save can turn one deliberate `:write` into several BufWritePost
--- events in quick succession (the phase's `save_cadence` decision, c-6);
--- each `trigger()` restarts a short quiet-period timer rather than firing
--- immediately, so only the last trigger in a burst survives to call back.
---
--- `new_timer` is an injectable dependency, defaulting to a real
--- `vim.uv.new_timer`, so tests exercise the coalescing logic against a fake
--- timer instead of sleeping on a real clock — the same shape diff.lua (t-3)
--- uses for `vim.diff`.

local M = {}

local DEFAULT_DELAY_MS = 750

---@return table timer-like object: `timer:start(timeout, repeat_ms, fn)`, `timer:stop()`
local function real_new_timer()
  return vim.uv.new_timer()
end

---@class CodriverDebouncer
---@field trigger fun() Restart the quiet-period window; never calls back synchronously.

---Build a debouncer around `callback`.
---@param callback fun()
---@param delay_ms integer|nil quiet-period length in ms. Defaults to 750.
---@param new_timer function|nil defaults to a real vim.uv timer; injectable for tests
---@return CodriverDebouncer
function M.new(callback, delay_ms, new_timer)
  delay_ms = delay_ms or DEFAULT_DELAY_MS
  new_timer = new_timer or real_new_timer

  local timer = nil

  local function trigger()
    if timer == nil then
      timer = new_timer()
    else
      timer:stop()
    end
    timer:start(delay_ms, 0, callback)
  end

  return { trigger = trigger }
end

return M
