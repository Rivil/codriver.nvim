---@brief Turns a buffer's current lines into changed-line hunks since its
--- last review snapshot (t-2), using Neovim's built-in `vim.diff()` rather
--- than a hand-rolled line-compare — the phase's rationale being that a
--- bespoke algorithm risks off-by-one anchor bugs a well-tested primitive
--- already avoids.
---
--- `diff_fn` is accepted as an optional 3rd argument, defaulting to
--- `vim.diff`, the same injectable-dependency shape as the debounce module
--- (t-4) uses for its timer — it is what lets this module's identity-check
--- fast path and hunk-shaping logic be exercised under bare LuaJIT, where
--- `vim.diff` (a real-Neovim C binding) does not exist.

local snapshot = require("codriver.review.snapshot")

local M = {}

---@class CodriverReviewHunk
---@field start_line integer 1-indexed first changed line in the new buffer.
---@field end_line integer 1-indexed last changed line in the new buffer.

---Changed-line hunks between bufnr's last snapshot and `lines`.
---
---Returns `nil` when bufnr has never been snapshotted — there is nothing to
---diff against. Returns `{}` when `lines` is identical to the snapshot,
---without calling `diff_fn` at all.
---@param bufnr integer
---@param lines string[]
---@param diff_fn function|nil defaults to `vim.diff`
---@return CodriverReviewHunk[]|nil
function M.diff(bufnr, lines, diff_fn)
  local old = snapshot.get(bufnr)
  if not old then
    return nil
  end

  local old_text = table.concat(old, "\n")
  local new_text = table.concat(lines, "\n")
  if old_text == new_text then
    return {}
  end

  diff_fn = diff_fn or vim.diff

  local raw = diff_fn(old_text .. "\n", new_text .. "\n", {
    result_type = "indices",
    algorithm = "minimal",
  })

  local hunks = {}
  for _, entry in ipairs(raw or {}) do
    local start_b, count_b = entry[3], entry[4]
    if count_b > 0 then
      table.insert(hunks, { start_line = start_b, end_line = start_b + count_b - 1 })
    else
      -- A pure deletion in the new buffer: nothing to underline in `lines`
      -- itself, but the point it was removed near is still worth anchoring.
      table.insert(hunks, { start_line = start_b, end_line = start_b })
    end
  end
  return hunks
end

return M
