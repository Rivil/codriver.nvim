-- Stop-hook receiver wiring parsed comments to render — run under real
-- Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/review_notify_check.lua
--
-- c-4: comments route to the right buffer's render.show(), a comment for an
-- unopened file is dropped without raising, several comments for one buffer
-- collapse into a single render.show() call, and a stray duplicate Stop
-- event for an already-rendered review is a no-op.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local notify = require("codriver.review.notify")

local ns = vim.api.nvim_create_namespace("codriver.review")

local bufnr = vim.api.nvim_create_buf(false, true)
local bufname = vim.fn.tempname() .. "-review-notify-target.lua"
vim.api.nvim_buf_set_name(bufnr, bufname)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three" })

-- ---------------------------------------------------------- single comment ---

notify.arm()
notify.received({ comments = { { file = bufname, line = 2, text = "x" } } })

local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
harness.expect_eq(#marks, 1, "one comment for an open buffer must produce exactly one extmark")

-- ------------------------------------------------------- unmatched buffer ---

harness.expect_eq(vim.fn.bufnr("/nowhere/never-opened.lua"), -1, "the fixture path must not resolve to a real buffer")

notify.arm()
local ok = pcall(notify.received, { comments = { { file = "/nowhere/never-opened.lua", line = 1, text = "x" } } })
harness.expect(ok, "a comment naming a file with no matching loaded buffer must not raise")

-- ------------------------------------------------------- one render.show ---
--
-- Proven indirectly: render.show() clears bufnr's prior extmarks before
-- drawing, so if notify.received() called it once per comment instead of
-- once for the whole buffer, the second call would wipe the first mark and
-- only one of the two would survive.

notify.arm()
notify.received({
  comments = {
    { file = bufname, line = 1, text = "first" },
    { file = bufname, line = 2, text = "second" },
  },
})

marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
harness.expect_eq(#marks, 2, "two comments for the same buffer must arrive as one render.show() call, not two")

-- ----------------------------------------------------------- stray duplicate ---
--
-- No arm() call between this and the render above: a second notify.received()
-- for the same pending review must be a no-op.

notify.received({ comments = { { file = bufname, line = 3, text = "should not render" } } })

local after = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
harness.expect_eq(#after, 2, "a stray duplicate notify.received() for an already-rendered review must be a no-op")

vim.api.nvim_buf_delete(bufnr, { force = true })

harness.ok(
  "notify.received() routes comments to render.show() per target buffer, drops comments for unopened "
    .. "files without raising, collapses multiple comments into one render call, and ignores a stray "
    .. "duplicate Stop event for an already-rendered review"
)
