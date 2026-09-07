---@brief Renders the role indicator into the built-in winbar.
---
--- Impure counterpart to codriver.statusline: registers the
--- CodriverNavigator/CodriverDriver highlight groups via `nvim_set_hl` and
--- writes codriver.statusline's text/highlight into the winbar. Subscribed
--- to codriver.role's on_change so the indicator repaints itself with no
--- polling.
---
--- `show()`/`hide()` are the public toggle. Wired here into codriver.init's
--- setup() for now; a later task re-points the calls at the session
--- lifecycle instead, so the indicator only exists while a session is
--- active (the phase's no_session_lifecycle decision) — this module owns
--- that state either way, not codriver.init directly.

local M = {}

local role = require("codriver.role")
local statusline = require("codriver.statusline")

---@type fun()|nil unsubscribe from role.on_change, set while shown
local unsubscribe = nil

---Register the highlight groups codriver.statusline names. Safe to call
---repeatedly — `nvim_set_hl` replaces a definition, it does not stack.
local function define_highlights()
  for name, attrs in pairs(statusline.highlights) do
    vim.api.nvim_set_hl(0, name, attrs)
  end
end

---Paint the winbar from the given role, or the currently held one.
---@param current_role CodriverRole|nil
local function render(current_role)
  local part = statusline.component(current_role or role.get())
  vim.o.winbar = ("%%#%s#%s"):format(part.highlight, part.text)
end

---Show the role indicator, and keep it live across role changes.
function M.show()
  define_highlights()
  render()

  if not unsubscribe then
    unsubscribe = role.on_change(render)
  end
end

---Hide the role indicator and stop tracking role changes.
function M.hide()
  vim.o.winbar = ""

  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
end

return M
