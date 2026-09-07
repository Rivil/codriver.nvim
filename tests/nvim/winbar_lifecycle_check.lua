-- Winbar lifecycle — run under real Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/winbar_lifecycle_check.lua
--
-- c-4: the indicator exists only while a session does. Drives the real
-- `:CodriverStart` / `:CodriverStop` and the real `VimLeavePre` autocmd
-- (fired directly, rather than by quitting — quitting would end this check's
-- own process), not codriver.winbar's show()/hide() directly, so a wiring
-- mistake in codriver.init shows up here rather than only in a unit test of
-- winbar itself.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

---A terminal provider that puts nothing on screen — see session_lifecycle_check.lua.
---@return table
local function stub_provider()
  local provider = {}
  for _, name in ipairs({ "setup", "open", "close", "simple_toggle", "focus_toggle" }) do
    provider[name] = function() end
  end
  provider.get_active_bufnr = function()
    return nil
  end
  provider.is_available = function()
    return true
  end
  return provider
end

require("codriver").setup({ claudecode = { terminal = { provider = stub_provider() } } })

local role = require("codriver.role")

---Fire the shutdown autocmd without actually leaving — quitting would end
---this check's own process before it could assert anything.
local function fire_vim_leave_pre()
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "CodriverShutdown" })
end

-- ------------------------------------------------- before any session ---

local cold_winbar = vim.o.winbar

-- --------------------------------------------------------- start / stop ---

vim.cmd("CodriverStart")
local started_winbar = vim.o.winbar

vim.cmd("CodriverStop")
local stopped_winbar = vim.o.winbar

-- ------------------------------------------------------------ VimLeavePre ---

vim.cmd("CodriverStart")
local restarted_winbar = vim.o.winbar
fire_vim_leave_pre()
local left_winbar = vim.o.winbar

-- ---------------------------------------------------- start, stop, start ---
-- A leftover-text bug would show up as the driver label surviving into the
-- fresh navigator session below.

vim.cmd("CodriverStart")
vim.cmd("CodriverHandover")
vim.cmd("CodriverStop")
role.set("navigator")
vim.cmd("CodriverStart")
local cycled_winbar = vim.o.winbar

vim.cmd("CodriverStop")

-- ---------------------------------------------------------------- assert ---

harness.expect_eq(cold_winbar, "", "the winbar shows role text before any session has started")

harness.expect_contains(started_winbar, "watching", "the winbar does not show the role after :CodriverStart")
harness.expect_eq(stopped_winbar, "", "the winbar still shows role text after :CodriverStop")

harness.expect_contains(restarted_winbar, "watching", "the winbar does not show the role after a restart")
harness.expect_eq(left_winbar, "", "the winbar survived VimLeavePre")

harness.expect_contains(cycled_winbar, "watching", "the restarted winbar does not show the current (navigator) role")
harness.expect_not_contains(
  cycled_winbar,
  "writing",
  "the driver label from the prior session leaked into the new one"
)

harness.ok("the winbar is absent before a session, shown while one runs, and cleared by stop and by VimLeavePre")
