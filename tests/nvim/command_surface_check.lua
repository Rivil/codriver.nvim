-- Command-surface fidelity and drift — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/command_surface_check.lua
--
-- c-7: the vendored commands have to be *reachable* under `:Codriver*` names —
-- not merely present. Three ways that fails, and this check covers all three:
--
--   * drift — an upstream re-sync adds or renames a vendored command and
--     codriver.commands.map does not answer it;
--   * lost options — `:'<,'>CodriverSend` or `:CodriverSendText!` stop parsing,
--     because a re-exported command dropped `range`, `nargs` or `bang`;
--   * a name with nothing behind it — the command exists and does nothing, or
--     raises.
--
-- No fixture here on purpose: t-12 owns coexistence, and a bug in its fixture
-- must never be able to read as a c-7 failure.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local codriver = require("codriver")
local commands = require("codriver.commands")
local server = require("codriver.vendor.claudecode.server.init")
local vendor = require("codriver.vendor.claudecode")

---A terminal provider that puts nothing on screen. The seven functions are the
---vendored provider contract.
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

codriver.setup({ claudecode = { terminal = { provider = stub_provider() } } })
vim.cmd("CodriverStart")

harness.expect_eq(server.get_status().running, true, "CodriverStart did not bring the server up")

-- Five of the fifteen vendored commands sit behind `if terminal_ok then`. When
-- that require fails they simply do not exist, and the drift assertion below
-- would report five unexplained absences instead of the one cause.
local terminal_ok, terminal_err = pcall(require, "codriver.vendor.claudecode.terminal")
if not terminal_ok then
  harness.fail(
    "the vendored terminal module does not load, so ClaudeCode/Focus/Open/Close/SendText were never registered: %s",
    tostring(terminal_err)
  )
end

-- --------------------------------------------------------------- drift ---
-- Captured against the real vendored registration, not against a list written
-- out here — a second copy of the surface would drift on its own.

local captured = commands.capture(vendor._create_commands)
harness.expect(#captured > 0, "the vendored layer registered no commands at all")

local registered = vim.api.nvim_get_commands({})

for _, entry in ipairs(captured) do
  harness.expect(
    commands.map[entry.name],
    "the vendored layer registers %s, which has no :Codriver* name — a re-sync added or renamed a command",
    entry.name
  )
end

for vendored_name, target in pairs(commands.map) do
  harness.expect(
    registered[target] ~= nil,
    "%s is mapped to :%s, but no such command is registered",
    vendored_name,
    target
  )
end

for name in pairs(registered) do
  harness.expect_not_contains(name, "ClaudeCode", "a vendored command name leaked into the registered surface")
end

-- ------------------------------------------------------- option fidelity ---
-- `nvim_get_commands` normalises what registration accepts: `range = true`
-- comes back as ".", an absent `nargs` as "0". So the comparison normalises
-- both sides rather than pretending the two shapes are the same.

---@param opts table
---@return table
local function as_registered(opts)
  return {
    ranged = opts.range ~= nil and opts.range ~= false,
    nargs = tostring(opts.nargs or "0"),
    bang = opts.bang == true,
    complete = opts.complete or "(none)",
  }
end

for _, entry in ipairs(captured) do
  local target = commands.map[entry.name]
  local want = as_registered(entry.opts)
  local got = as_registered(registered[target])

  -- Start/Stop/Status are answered by codriver itself (c-4), and the vendored
  -- three carry no flags to preserve, so they compare equal like the rest.
  for _, flag in ipairs({ "ranged", "nargs", "bang", "complete" }) do
    harness.expect_eq(got[flag], want[flag], (":%s lost the vendored %s of :%s"):format(target, flag, entry.name))
  end
end

-- Spelled out as well, because these three are the ones a user notices: they
-- are what make `:'<,'>CodriverSend`, `:CodriverAdd <tab>` and
-- `:CodriverSendText!` parse at all.
harness.expect_eq(registered.CodriverSend.range, ".", ":CodriverSend does not accept a range")
harness.expect_eq(registered.CodriverAdd.nargs, "+", ":CodriverAdd does not take arguments")
harness.expect_eq(registered.CodriverAdd.complete, "file", ":CodriverAdd lost file completion")
harness.expect_eq(registered.CodriverSendText.bang, true, ":CodriverSendText! is not accepted")

-- ------------------------------------------------ the handlers behind them ---
-- A registered name proves nothing on its own. These two put something in the
-- vendored @-mention queue, which holds while no client is connected — so the
-- queue is a readable record of the vendored handler having actually run.

vim.cmd("lcd " .. vim.fn.fnameescape(harness.repo_root))

---@return table[]
local function queue()
  return vendor.state.mention_queue or {}
end

vendor.state.mention_queue = {}
vim.cmd("CodriverAdd README.md")

harness.expect_eq(#queue(), 1, "CodriverAdd queued " .. #queue() .. " mentions, not one")
harness.expect_eq(queue()[1].file_path, "README.md", "CodriverAdd queued the wrong path")

local file = vim.fn.tempname() .. ".txt"
vim.fn.writefile({ "first line", "second line", "third line" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))

-- Read back rather than reused from `file`: on macOS the temp root is a
-- symlink, so the buffer's name is the resolved path and the mention will
-- carry that. "Names the file that is selected" is the contract either way.
local buffer_name = vim.api.nvim_buf_get_name(0)
harness.expect(buffer_name ~= "", "the fixture file did not open into a named buffer")

vendor.state.mention_queue = {}
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Vj<Esc>", true, false, true), "x", false)
vim.cmd("'<,'>CodriverSend")

harness.expect_eq(#queue(), 1, "'<,'>CodriverSend queued " .. #queue() .. " mentions, not one")
harness.expect_eq(queue()[1].file_path, buffer_name, "'<,'>CodriverSend queued a mention for the wrong file")

-- ------------------------------------------------------ diff and model ---
-- Named but unwired is the failure mode here: both of these are reached with
-- nothing to act on, and both must complete rather than raise.

local diff_ok, diff_err = pcall(vim.cmd, "CodriverDiffAccept")
harness.expect(diff_ok, "CodriverDiffAccept raised with no diff open: %s", tostring(diff_err))

local real_select = vim.ui.select
vim.ui.select = function(_, _, on_choice)
  on_choice(nil) -- the user pressed <Esc>
end
local model_ok, model_err = pcall(vim.cmd, "CodriverSelectModel")
vim.ui.select = real_select
harness.expect(model_ok, "CodriverSelectModel raised when the selection was cancelled: %s", tostring(model_err))

-- ---------------------------------------------------------------- teardown ---

vim.cmd("bwipeout!")
vim.fn.delete(file)

harness.expect(pcall(vim.cmd, "CodriverStop"), "CodriverStop threw")
harness.expect_eq(#harness.lock_files(), 0, "lockfiles left behind")

harness.ok("every vendored command is reachable under its :Codriver* name, with its flags and its handler intact")
