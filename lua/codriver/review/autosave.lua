---@brief Wires a debounced `BufWritePost` review trigger (c-1, c-2, c-3, c-5,
--- c-6): a save while Claude is navigator and `review_on_save` is on diffs
--- the buffer against its last snapshot (t-2/t-3) and, if anything changed,
--- dispatches the built prompt (t-5) through `send_to_terminal` — the same
--- delivery mechanism `:CodriverSend` uses (the phase's `delivery_mechanism`
--- decision). Saves are debounced (t-4) so a format-on-save burst of
--- BufWritePost events coalesces into one review request.

local debounce_mod = require("codriver.review.debounce")
local diff_mod = require("codriver.review.diff")
local prompt_mod = require("codriver.review.prompt")
local snapshot = require("codriver.review.snapshot")

local M = {}

local GROUP = "CodriverReviewOnSave"

---@class CodriverAutosaveOpts
---@field review_on_save boolean
---@field role table|nil defaults to codriver.role; exposes is_navigator()
---@field send_to_terminal fun(text: string, opts: table): boolean|nil defaults to the vendored terminal's send_to_terminal
---@field delay_ms integer|nil debounce quiet-period; defaults to debounce.lua's own default
---@field new_timer function|nil injectable timer factory, forwarded to debounce.new

---Review bufnr's current content against its last snapshot and dispatch a
---prompt for whatever changed. Nothing to diff against yet (bufnr has never
---been reviewed) just establishes that baseline rather than reviewing
---content that predates `review_on_save` being turned on for this buffer.
---The snapshot only advances on a successful send, so a dropped send (no
---terminal open) leaves the next save's diff still covering these changes.
---@param bufnr integer
---@param opts CodriverAutosaveOpts
local function fire(bufnr, opts)
  if not opts.review_on_save then
    return
  end

  local role = opts.role or require("codriver.role")
  if not role.is_navigator() then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  if not snapshot.get(bufnr) then
    snapshot.advance(bufnr, lines)
    return
  end

  local hunks = diff_mod.diff(bufnr, lines)
  if not hunks or #hunks == 0 then
    return
  end

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local text = prompt_mod.build(bufname, hunks)

  local send_to_terminal = opts.send_to_terminal
    or require("codriver.vendor.claudecode.terminal").send_to_terminal
  local ok = send_to_terminal(text, { submit = true })
  if ok then
    snapshot.advance(bufnr, lines)
  end
end

---Install the debounced `BufWritePost` autocmd. Safe to call more than once
---— it (re)creates its own augroup with `clear = true`, the same pattern
---init.lua's shutdown autocmd uses.
---@param opts CodriverAutosaveOpts
function M.install(opts)
  opts = opts or {}

  local debouncers = {}

  vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = GROUP,
    callback = function(args)
      local bufnr = args.buf
      local debouncer = debouncers[bufnr]
      if not debouncer then
        -- The timer callback runs in a fast-event ("lua loop callback")
        -- context where nvim_buf_*/nvim_api_* calls are not allowed;
        -- schedule_wrap defers the actual review back onto the main loop.
        debouncer = debounce_mod.new(
          vim.schedule_wrap(function()
            fire(bufnr, opts)
          end),
          opts.delay_ms,
          opts.new_timer
        )
        debouncers[bufnr] = debouncer
      end
      debouncer.trigger()
    end,
    desc = "codriver: debounced ambient review request on save",
  })
end

return M
