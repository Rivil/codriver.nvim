-- Extmark review-comment renderer — run under real Neovim by `mise run
-- test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/review_render_check.lua
--
-- c-4: comments render as virtual text extmarks in codriver's own namespace,
-- a second render clears the first before drawing, and an out-of-range line
-- is skipped rather than raised.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local render = require("codriver.review.render")

-- Namespace creation is idempotent by name, so this resolves to the same
-- namespace render.lua draws into.
local ns = vim.api.nvim_create_namespace("codriver.review")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three" })

render.show(bufnr, { { line = 3, text = "nit" } })

local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
harness.expect_eq(#marks, 1, "one comment must draw exactly one extmark")

render.show(bufnr, { { line = 1, text = "first" }, { line = 2, text = "second" } })

marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
harness.expect_eq(#marks, 2, "a second render.show() must clear the first call's extmarks before drawing new ones")

local ok = pcall(render.show, bufnr, { { line = 999, text = "out of range" }, { line = 2, text = "valid" } })
harness.expect(ok, "an out-of-range line must be skipped, not raised")

marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
harness.expect_eq(#marks, 1, "the out-of-range comment must be skipped while the valid one in the same payload still renders")

vim.api.nvim_buf_delete(bufnr, { force = true })

harness.ok(
  "render.show(bufnr, comments) draws one extmark per entry in codriver's own namespace, "
    .. "clears before redrawing, and clamps/skips out-of-range lines without raising"
)
