---@brief Synthesizes the review request text sent to Claude on save.
---
--- Names the buffer and lists only the ranges diff.lua (t-3) found changed —
--- never the whole file (c-1, c-3) — then asks for the literal
--- `REVIEW <path>:<line>: <comment>` grammar parse.lua (t-6) keys on, so the
--- prompt and its parser never drift out of sync.

local M = {}

---@param hunk CodriverReviewHunk
---@return string
local function range_label(hunk)
  if hunk.start_line == hunk.end_line then
    return tostring(hunk.start_line)
  end
  return ("%d-%d"):format(hunk.start_line, hunk.end_line)
end

---Build the review request text for `bufname`'s changed `hunks`.
---@param bufname string
---@param hunks CodriverReviewHunk[]
---@return string
function M.build(bufname, hunks)
  local ranges = {}
  for _, hunk in ipairs(hunks) do
    table.insert(ranges, range_label(hunk))
  end

  local lines = {
    ("Review the changes in %s at line%s %s."):format(
      bufname,
      #ranges == 1 and "" or "s",
      table.concat(ranges, ", ")
    ),
    "Only comment on the changed range above, not the rest of the file.",
    "For each comment, reply with a line in exactly this form:",
    "REVIEW " .. bufname .. ":<line>: <comment>",
    "Emit one such line per comment, and nothing else if you have no comments.",
  }

  return table.concat(lines, "\n")
end

return M
