---@brief Draws parsed review comments (t-6) as virtual text extmarks,
--- anchored near the changed lines (c-4, the `rendering_surface` decision:
--- virtual text only, never a quickfix list, never buffer text). This module
--- never calls `nvim_buf_set_text` or anything else Edit/Write-shaped — it
--- only ever adds/clears extmarks in its own namespace.

local M = {}

local NS = vim.api.nvim_create_namespace("codriver.review")

---@class CodriverReviewRenderComment
---@field line integer 1-indexed line to anchor near.
---@field text string

---Draw `comments` in `bufnr`, replacing whatever this module previously drew
---there. A comment whose line falls outside the buffer (it may have shrunk
---since the diff that produced the comment) is skipped, not raised; every
---other comment in the same payload still renders.
---@param bufnr integer
---@param comments CodriverReviewRenderComment[]
function M.show(bufnr, comments)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, comment in ipairs(comments) do
    if comment.line >= 1 and comment.line <= line_count then
      vim.api.nvim_buf_set_extmark(bufnr, NS, comment.line - 1, 0, {
        virt_text = { { "  ● " .. comment.text, "Comment" } },
        virt_text_pos = "eol",
      })
    end
  end
end

return M
