-- Default Send/SendText keymaps — run under real Neovim by `mise run
-- test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/keymaps_check.lua
--
-- c-1/c-2/c-4: the default keymaps have to actually reach CodriverSend and
-- CodriverSendText, not just exist as registered lhs strings. c-5: a disabled
-- or overridden entry must never fall back to the default lhs.
--
-- The at-mention queueing assertions drive real keypresses through
-- vim.api.nvim_feedkeys — same technique, and the same vendored
-- `mention_queue` evidence, as command_surface_check.lua's `'<,'>CodriverSend`
-- assertions. `<leader>cS`'s "does not submit" is checked by inspecting the
-- registered rhs instead of simulating the interactive command-line: a
-- headless `-l` script has no real UI loop to hold a live Cmd-line wait in, so
-- the rhs having no trailing `<CR>` is the deterministic proof.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

-- Set before codriver.setup() runs: config.lua's default lhs strings use the
-- literal text "<leader>cs"/"<leader>cS", and vim.keymap.set resolves
-- "<leader>" against mapleader at the moment a mapping is defined.
vim.g.mapleader = " "

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

local codriver = require("codriver")
local keymaps = require("codriver.keymaps")
local vendor = require("codriver.vendor.claudecode")

codriver.setup({ claudecode = { terminal = { provider = stub_provider() } } })
vim.cmd("CodriverStart")

---@param mode string
---@param lhs string
---@return table|nil
local function get_map(mode, lhs)
  for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
    if entry.lhs == lhs then
      return entry
    end
  end
  return nil
end

-- ------------------------------------------------------ default registration ---

local n_send = get_map("n", " cs")
harness.expect(n_send ~= nil, "default <leader>cs is not mapped in normal mode after setup()")
harness.expect_eq(n_send and n_send.rhs, "<Cmd>CodriverSend<CR>", "normal-mode <leader>cs rhs")

local v_send = get_map("v", " cs")
harness.expect(v_send ~= nil, "default <leader>cs is not mapped in visual mode after setup()")
harness.expect_eq(v_send and v_send.rhs, ":CodriverSend<CR>", "visual-mode <leader>cs rhs")

local n_send_text = get_map("n", " cS")
harness.expect(n_send_text ~= nil, "default <leader>cS is not mapped after setup()")
harness.expect_eq(
  n_send_text and n_send_text.rhs,
  ":CodriverSendText ",
  "<leader>cS must prefill the command-line without a trailing <CR> to submit it"
)

-- ---------------------------------------------------------------- queueing ---

local file = vim.fn.tempname() .. ".txt"
vim.fn.writefile({ "one", "two", "three" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))

-- Read back rather than reused from `file`: on macOS the temp root is a
-- symlink, so the buffer's name is the resolved path.
local buffer_name = vim.api.nvim_buf_get_name(0)
harness.expect(buffer_name ~= "", "the fixture file did not open into a named buffer")

---@return table[]
local function queue()
  return vendor.state.mention_queue or {}
end

-- Whole-buffer selection held across <Esc>, then the normal-mode keymap. No
-- range is passed to CodriverSend this way — same as a bare `:CodriverSend`
-- — so it sends whatever selection tracking is still holding.
vendor.state.mention_queue = {}
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ggVG<Esc> cs", true, false, true), "x", false)

harness.expect_eq(#queue(), 1, "<leader>cs in normal mode queued " .. #queue() .. " mentions, not one")
harness.expect_eq(queue()[1].file_path, buffer_name, "<leader>cs in normal mode queued the wrong file")
harness.expect_eq(queue()[1].start_line, 0, "<leader>cs in normal mode did not cover the whole buffer")
harness.expect_eq(queue()[1].end_line, 2, "<leader>cs in normal mode did not cover the whole buffer")

-- Partial visual range, triggered while still in Visual mode. Leaving Visual
-- mode via `:` is what makes Neovim insert the `'<,'>` range itself, scoping
-- the mention to exactly the two selected lines rather than the whole buffer.
vendor.state.mention_queue = {}
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Vj cs", true, false, true), "x", false)

harness.expect_eq(#queue(), 1, "<leader>cs in visual mode queued " .. #queue() .. " mentions, not one")
harness.expect_eq(queue()[1].file_path, buffer_name, "<leader>cs in visual mode queued the wrong file")
harness.expect_eq(queue()[1].start_line, 0, "<leader>cs in visual mode must cover exactly the selection")
harness.expect_eq(queue()[1].end_line, 1, "<leader>cs in visual mode sent the whole buffer, not just the selection")

-- ------------------------------------------------------- disable / override ---
--
-- Exercised directly through keymaps.apply() — the same function setup()
-- calls with config.lua's resolved table. resolve_keys() (t-1) already proved
-- a disabled entry is omitted from that table; this proves apply() honours
-- the omission by never mapping it and never falling back to the default lhs.

vim.keymap.del("n", " cs")
vim.keymap.del("v", " cs")

-- What config.resolve() hands apply() when opts.keys.send = false: the `send`
-- key simply is not there.
keymaps.apply({ send_text = "<leader>cS" })

harness.expect(get_map("n", " cs") == nil, "disabling send must not leave <leader>cs mapped in normal mode")
harness.expect(get_map("v", " cs") == nil, "disabling send must not leave <leader>cs mapped in visual mode")

keymaps.apply({ send = "<leader>xx" })

harness.expect(get_map("n", " xx") ~= nil, 'opts.keys.send = "<leader>xx" must bind the custom lhs in normal mode')
harness.expect(get_map("v", " xx") ~= nil, 'opts.keys.send = "<leader>xx" must bind the custom lhs in visual mode')
harness.expect(get_map("n", " cs") == nil, "a custom lhs must not also leave the default <leader>cs mapped")
harness.expect(get_map("v", " cs") == nil, "a custom lhs must not also leave the default <leader>cs mapped")

-- ------------------------------------------------------------------ teardown ---

vim.cmd("bwipeout!")
vim.fn.delete(file)

harness.expect(pcall(vim.cmd, "CodriverStop"), "CodriverStop threw")
harness.expect_eq(#harness.lock_files(), 0, "lockfiles left behind")

harness.ok("<leader>cs/<leader>cS reach CodriverSend/CodriverSendText, respect overrides, and honour opts.keys disables")
