---@brief What the role looks like, rendered.
---
--- Pure formatting: no `vim.*` calls, no reaching into `codriver.role`. It is
--- handed a role and returns text plus a highlight name — mirroring
--- `codriver.status`'s split of pure formatting from impure wiring.
---
--- `codriver.winbar` is the impure module that registers the highlight groups
--- named here via `nvim_set_hl` and renders this module's output into the
--- winbar. `component()` below exists for anyone who would rather wire it into
--- their own lualine/heirline config instead, per the indicator_surface
--- decision.

local M = {}

---Label text and highlight group share no stem: a colorblind- and
---glance-safe reading can't fall back to inferring one role from the other's
---word, the same reasoning codriver.status applies to its two states.
local NAVIGATOR_LABEL = "watching"
local DRIVER_LABEL = "writing"

---@type table<string, vim.api.keyset.highlight>
M.highlights = {
  CodriverNavigator = { fg = "#61afef", bold = true },
  CodriverDriver = { fg = "#e06c75", bold = true },
}

---@class CodriverStatuslineComponent
---@field text string
---@field highlight string

---Render the current role as label text plus the highlight group that styles
---it.
---@param role CodriverRole
---@return CodriverStatuslineComponent
function M.component(role)
  if role == "driver" then
    return { text = DRIVER_LABEL, highlight = "CodriverDriver" }
  end

  return { text = NAVIGATOR_LABEL, highlight = "CodriverNavigator" }
end

return M
