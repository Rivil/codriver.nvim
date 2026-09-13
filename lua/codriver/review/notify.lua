---@brief RPC receiver the Stop hook (t-11) calls with a review's parsed
--- comments (t-6), routing them to render.show() (t-8) for each comment's
--- target buffer (c-4).
---
--- Guards against a stray second Stop event for the same review: `arm()`
--- marks the module ready to accept the *next* review's comments — called by
--- whoever dispatches the review request (t-10's autosave trigger, t-11's
--- hook registration) right before sending the prompt — and `received()`
--- clears that marker on its first successful call. A module freshly loaded
--- starts armed, so the very first review in a session needs no separate
--- initial arm() call.

local render = require("codriver.review.render")

local M = {}

local pending = true

---Arm the module to accept the next received() call.
function M.arm()
  pending = true
end

---@class CodriverReviewNotifyComment
---@field file string
---@field line integer
---@field text string

---Route `payload.comments` to render.show(), one call per target buffer. A
---comment naming a file with no matching loaded buffer (`vim.fn.bufnr`
---returns -1) is dropped silently — there is nothing open to anchor it to.
---
---A no-op once this review's comments have already been rendered once: see
---the module brief for the arm()/received() pairing.
---@param payload { comments: CodriverReviewNotifyComment[] }
function M.received(payload)
  if not pending then
    return
  end
  pending = false

  local by_buf = {}
  local order = {}
  for _, comment in ipairs((payload or {}).comments or {}) do
    local bufnr = vim.fn.bufnr(comment.file)
    if bufnr ~= -1 then
      if not by_buf[bufnr] then
        by_buf[bufnr] = {}
        table.insert(order, bufnr)
      end
      table.insert(by_buf[bufnr], { line = comment.line, text = comment.text })
    end
  end

  for _, bufnr in ipairs(order) do
    render.show(bufnr, by_buf[bufnr])
  end
end

return M
