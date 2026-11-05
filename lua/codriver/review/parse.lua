---@brief Parses `REVIEW <path>:<line>: <comment>` lines out of Claude's
--- reply text (the grammar prompt.lua, t-5, asks for) into structured
--- entries for render.lua (t-8) to draw.

local M = {}

---@class CodriverReviewComment
---@field file string
---@field line integer
---@field text string

---Parse every `REVIEW <path>:<line>: <comment>` line in `text`.
---
---A line that doesn't match the grammar at all is ignored — ordinary prose
---in the same reply. A line that matches but whose `<line>` field isn't a
---plain integer is skipped rather than raised: transcript text is free-form
---prose Claude wrote, not a contract this module can enforce on the other
---end.
---@param text string
---@return CodriverReviewComment[]
function M.parse(text)
  local comments = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local file, line_str, comment = line:match("^REVIEW%s+(.-):([^:%s]+):%s*(.*)$")
    if file then
      local line_num = tonumber(line_str)
      if line_num then
        table.insert(comments, { file = file, line = line_num, text = comment })
      end
    end
  end
  return comments
end

return M
