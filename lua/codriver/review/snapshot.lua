---@brief Per-buffer snapshot of the buffer content as of the last review.
---
--- Ambient review (t-3 onward) diffs the live buffer against this snapshot,
--- never against the whole file or a git ref (the phase's `diff_basis`
--- decision) — so a review only ever covers what changed since the *last*
--- review, not everything since the file was opened. `advance()` is the only
--- writer; callers move the snapshot forward once a review has actually
--- fired, not on every save.
---
--- Pure in-memory state keyed by bufnr. No vim API at all, so this is tested
--- under bare LuaJIT like codriver.config — see tests/busted_setup.lua.

local M = {}

---@type table<integer, string[]>
local snapshots = {}

---Record `lines` as bufnr's snapshot, replacing whatever was there before.
---@param bufnr integer
---@param lines string[]
function M.advance(bufnr, lines)
  snapshots[bufnr] = lines
end

---The last snapshot recorded for bufnr, or nil if none has been taken (or it
---was cleared).
---@param bufnr integer
---@return string[]|nil
function M.get(bufnr)
  return snapshots[bufnr]
end

---Drop bufnr's snapshot. Called on buffer wipeout so a recycled bufnr never
---diffs its new content against a different file's stale snapshot.
---@param bufnr integer
function M.clear(bufnr)
  snapshots[bufnr] = nil
end

return M
