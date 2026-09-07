-- Winbar indicator — run under real Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/winbar_check.lua
--
-- Drives c-1/c-2 through the real setup() path and the real
-- :CodriverHandover command, not by calling codriver.winbar directly — a
-- unit test of winbar.show() would pass happily while setup() still forgot
-- to call it.
--
-- No explicit redraw command is issued anywhere below: if the winbar only
-- updated on the next lazy redraw, this check would still read stale text
-- and fail the "pushed, not polled" claim rather than pass it by accident.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

require("codriver").setup({})

local role = require("codriver.role")

-- ---------------------------------------------------------------- gather ---

local navigator_winbar = vim.o.winbar
local navigator_hl = vim.api.nvim_get_hl(0, { name = "CodriverNavigator" })
local driver_hl = vim.api.nvim_get_hl(0, { name = "CodriverDriver" })

vim.cmd("CodriverHandover")
local driver_winbar = vim.o.winbar

role.set("navigator")
local back_to_navigator_winbar = vim.o.winbar

-- ---------------------------------------------------------------- assert ---

harness.expect(next(navigator_hl) ~= nil, "CodriverNavigator has no highlight definition after setup()")
harness.expect(next(driver_hl) ~= nil, "CodriverDriver has no highlight definition after setup()")

harness.expect_contains(navigator_winbar, "watching", "the navigator role's label text is not in the winbar")

harness.expect_contains(driver_winbar, "writing", "the winbar was not pushed to the driver label by :CodriverHandover")
harness.expect_not_contains(driver_winbar, "watching", "the navigator label lingered after handing over")

harness.expect_contains(
  back_to_navigator_winbar,
  "watching",
  "role.set() back to navigator did not push a repaint to the winbar"
)

harness.ok("winbar shows the role's label after setup and repaints on role.on_change with no explicit redraw")
