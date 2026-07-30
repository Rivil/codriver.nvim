-- Buffer and selection reachability — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/mcp_context_check.lua
--
-- c-3 says Claude can read the buffer you are actually looking at — unsaved
-- edits and all — without you pasting anything. Claude asks for that over
-- JSON-RPC, so this drives the real dispatcher
-- (`server.state.handlers["tools/call"]`) against a stub client rather than
-- calling the tool modules directly: a tool that stopped being registered, or a
-- start path that skipped `tools.setup`, has to surface here as the -32601 the
-- real Claude would get.
--
-- Codriver owns none of these tools. What it owns is the `track_selection`
-- default (codriver.config) and the forwarding of the resolved config into the
-- vendored start (codriver.session) — so a failure here is fixed in one of
-- those two files, and never in `vendor/`.
--
-- Ordering is load-bearing twice over:
--
--   * the no-selection case runs before anything has been selected, because
--     `latest_selection` persists once set;
--   * the buffer is edited *before* visual mode is entered, because
--     `flush_visual_selection` deliberately skips when the changedtick moved
--     while the selection was up (it cannot tell `d` from `gU`).

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local codriver = require("codriver")
local selection = require("codriver.vendor.claudecode.selection")
local server = require("codriver.vendor.claudecode.server.init")

local DISK_LINE = "the line as it is on disk"
local EDITED_LINE = "the line as it is in the buffer, never written"

---A terminal provider that puts nothing on screen. `:CodriverStart` opens a
---terminal along with the session, and a headless process has nowhere to put
---one — nor any business launching a real `claude`. The seven functions are the
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

-- The tools are registered against the server by the vendored start, so the
-- dispatcher is only meaningful once there is one.
local handlers = server.state.handlers or {}
harness.expect(
  type(handlers["tools/call"]) == "function" and type(handlers["tools/list"]) == "function",
  "the JSON-RPC dispatcher has no tools/call or tools/list handler — the session came up without its tool surface"
)

---Stands in for Claude. Only the coroutine-backed blocking tools ever look at
---it, and none of the context tools are blocking.
local client = { id = "mcp_context_check" }

---Invoke a tool the way Claude does, and hand back its decoded payload.
---
---An unregistered tool answers `-32601 Tool not found`, which is named here
---rather than left to surface as a nil index three assertions later.
---@param name string
---@param arguments table|nil
---@return table payload
local function call_tool(name, arguments)
  local result, err = handlers["tools/call"](client, { name = name, arguments = arguments or vim.empty_dict() })

  if err then
    harness.fail("%s: the tool call failed with %s %s", name, tostring(err.code), tostring(err.message))
  end

  local text = type(result) == "table" and result.content and result.content[1] and result.content[1].text
  if type(text) ~= "string" then
    harness.fail("%s: the tool returned no text content — got %s", name, vim.inspect(result))
  end

  local ok, payload = pcall(vim.json.decode, text)
  if not ok or type(payload) ~= "table" then
    harness.fail("%s: the tool's text content is not a JSON object: %s", name, text)
  end
  return payload
end

---The payload's `selection.isEmpty`, or nil if it has no selection at all.
---
---A function rather than an inline `a and b or c`: `isEmpty = false` is a real
---answer here, and that idiom turns it into nil.
---@param payload table
---@return boolean|nil
local function is_empty(payload)
  if type(payload.selection) ~= "table" then
    return nil
  end
  return payload.selection.isEmpty
end

-- ---------------------------------------------------- the context surface ---
-- Every tool c-3 leans on, present under the name Claude asks for. A config
-- that switched `track_selection` off, or a start that skipped `tools.setup`,
-- shows up here as a missing name rather than as a puzzling empty selection.

harness.expect_eq(selection.state.tracking_enabled, true, "selection tracking is not armed after CodriverStart")

local listed = {}
for _, tool in ipairs((handlers["tools/list"](client, {}) or {}).tools or {}) do
  listed[tool.name] = true
end

for _, name in ipairs({
  "getCurrentSelection",
  "getLatestSelection",
  "checkDocumentDirty",
  "saveDocument",
  "getOpenEditors",
}) do
  harness.expect(listed[name], "tools/list does not offer %s — Claude cannot ask for it", name)
end

-- ------------------------------------------------------------ the buffer ---
-- Written under the temp root, never into the repository: this check dirties a
-- buffer and writes it back.

local file = vim.fn.tempname() .. ".txt"
vim.fn.writefile({ DISK_LINE, "a second line" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))

-- ------------------------------------------------------ no selection yet ---
-- Nothing has been selected, so "no selection" is a state, not a failure. An
-- error here would reach Claude as a broken tool rather than an empty answer.

local empty = call_tool("getCurrentSelection")
harness.expect_eq(empty.success, true, "getCurrentSelection reports failure when there is simply no selection")
harness.expect_eq(
  is_empty(empty),
  true,
  "getCurrentSelection does not report an absent selection as empty: " .. vim.inspect(empty)
)

-- --------------------------------------------------------- dirty, or not ---

local clean = call_tool("checkDocumentDirty", { filePath = file })
harness.expect_eq(clean.success, true, "checkDocumentDirty does not recognise the open buffer: " .. vim.inspect(clean))
harness.expect_eq(clean.isDirty, false, "a freshly opened, unedited buffer is reported as dirty")

vim.api.nvim_buf_set_lines(0, 0, 1, false, { EDITED_LINE })

local dirty = call_tool("checkDocumentDirty", { filePath = file })
harness.expect_eq(dirty.isDirty, true, "a buffer with unwritten edits is not reported as dirty")

-- ---------------------------------------------------- the unsaved buffer ---
-- The whole of c-3. The edit above is in the buffer and nowhere else; if
-- getCurrentSelection answers with what is on disk, Claude is reading a stale
-- file and the user still has to paste.
--
-- `V` then `<Esc>` rather than a synthesised selection: leaving visual mode is
-- what fires the vendored `ModeChanged` handler, and that flush — from the
-- still-valid `'<`/`'>` marks — is the real path a user's selection travels.

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("V<Esc>", true, false, true), "x", false)

local selected = call_tool("getCurrentSelection")

harness.expect_eq(
  selected.success,
  true,
  "getCurrentSelection failed over a visual selection: " .. vim.inspect(selected)
)
harness.expect_contains(selected.text, EDITED_LINE, "getCurrentSelection did not return the unsaved buffer contents")
harness.expect_not_contains(selected.text, DISK_LINE, "getCurrentSelection returned the on-disk line, not the buffer's")
harness.expect_eq(is_empty(selected), false, "a real visual selection is reported as empty: " .. vim.inspect(selected))

-- --------------------------------------------------------- saved is clean ---

vim.cmd("silent write")

local written = call_tool("checkDocumentDirty", { filePath = file })
harness.expect_eq(written.isDirty, false, "the buffer is still reported as dirty after :w")

-- ---------------------------------------------------------------- teardown ---

vim.cmd("bwipeout!")
vim.fn.delete(file)

harness.expect(pcall(vim.cmd, "CodriverStop"), "CodriverStop threw")
harness.expect_eq(#harness.lock_files(), 0, "lockfiles left behind")

harness.ok(
  "Claude reaches the context tools, the unsaved buffer and the live visual selection over the real dispatcher"
)
