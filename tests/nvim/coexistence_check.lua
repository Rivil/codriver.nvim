-- Coexistence with a real claudecode.nvim — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/coexistence_check.lua
--
-- c-6: codriver has to run alongside an actual claudecode.nvim install without
-- either plugin shadowing the other. Every way that can go wrong is a name
-- collision, so this puts tests/fixtures/claudecode.nvim — which claims the
-- `claudecode` module namespace, the `:ClaudeCode*` command names, the
-- `ClaudeCodeShutdown` augroup and `lua/claudecode/health.lua`, each with a
-- marker — on runtimepath beside codriver, and checks that codriver's setup
-- leaves all four alone.
--
-- Its own process, and necessarily so: vendor_smoke_check.lua asserts that the
-- bare `claudecode` namespace is never loaded, and this check loads it on
-- purpose.
--
-- The `health.lua` assertion here is the outside view of the rename that
-- scripts/vendor-sync.sh performs. That script checks its own work; this checks
-- what the user would actually see.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

-- Prepended, so the fixture wins any resolution codriver might contest. If
-- codriver still comes out on top of something, that is the collision.
vim.opt.runtimepath:prepend(harness.repo_root .. "/tests/fixtures/claudecode.nvim")

-- Explicitly: the fixture joined runtimepath after Neovim scanned it, so its
-- plugin file has not been sourced.
vim.cmd("runtime! plugin/claudecode.lua")

local claudecode = require("claudecode")

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

---Every `:ClaudeCode*` command currently registered, sorted.
---@return string[]
local function claude_commands()
  local names = {}
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match("^ClaudeCode") then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

---@param group string
---@return table[]
local function autocmds(group)
  local ok, found = pcall(vim.api.nvim_get_autocmds, { group = group })
  return ok and found or {}
end

---@param group string
---@return boolean
local function has_fixture_autocmd(group)
  for _, autocmd in ipairs(autocmds(group)) do
    if type(autocmd.desc) == "string" and autocmd.desc:find("fixture", 1, true) then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------- module names ---

harness.expect_eq(claudecode.marker, "claudecode.nvim fixture", 'require("claudecode") did not resolve to the fixture')
harness.expect(
  claudecode ~= require("codriver.vendor.claudecode"),
  'require("claudecode") and require("codriver.vendor.claudecode") are the same table — the namespaces have collapsed'
)

-- ----------------------------------------------------- before codriver ran ---
-- Baseline, and proof the fixture is really standing in for something: its
-- commands exist and its handlers run.

local before = claude_commands()
harness.expect(#before > 0, "the fixture registered no :ClaudeCode* commands")

vim.cmd("ClaudeCodeStart")
harness.expect_eq(claudecode.invoked.ClaudeCodeStart, 1, "the fixture's own :ClaudeCodeStart did not run its handler")
harness.expect(has_fixture_autocmd("ClaudeCodeShutdown"), "the fixture registered no ClaudeCodeShutdown autocmd")

-- ------------------------------------------------------------- setup ----- ---

require("codriver").setup({ claudecode = { terminal = { provider = stub_provider() } } })

-- The vendored layer wants all fifteen of these names. Interception, not
-- cleanup: codriver never registers them, and — just as importantly — never
-- deletes them, because the ones that exist belong to the other plugin.
local after = claude_commands()
harness.expect_eq(
  table.concat(after, ", "),
  table.concat(before, ", "),
  "codriver changed the :ClaudeCode* command surface"
)

vim.cmd("ClaudeCodeStart")
harness.expect_eq(
  claudecode.invoked.ClaudeCodeStart,
  2,
  "the fixture's :ClaudeCodeStart stopped running the fixture's handler after codriver.setup"
)

harness.expect(
  vim.api.nvim_get_commands({}).CodriverStart ~= nil,
  "codriver registered no :CodriverStart — it yielded the whole surface rather than taking its own namespace"
)

-- ---------------------------------------------------------------- augroups ---
-- The one group codriver's capture shim renames. Renaming its own is the point;
-- creating `ClaudeCodeShutdown` with `clear = true` would wipe the other
-- plugin's VimLeavePre handler and leave it leaking its lockfile on exit.

harness.expect(
  has_fixture_autocmd("ClaudeCodeShutdown"),
  "codriver's setup destroyed the other plugin's ClaudeCodeShutdown handler — the bridge re-creates instead of renaming"
)
harness.expect(
  #autocmds("CodriverShutdown") > 0,
  "codriver has no CodriverShutdown autocmd — its own exit handler went missing in the rename"
)

-- -------------------------------------------------------------- checkhealth ---
-- `:checkhealth <name>` globs `lua/**/<name>/health.lua` by *directory* name.
-- Codriver's vendored tree lives in a directory called `claudecode`, so a file
-- named health.lua inside it would answer `:checkhealth claudecode` — and bare
-- `:checkhealth` — purely because codriver is installed.

local health_files = vim.api.nvim_get_runtime_file("lua/**/claudecode/health.lua", true)
harness.expect(
  #health_files > 0,
  "the glob matched nothing at all, not even the fixture's health.lua — this assertion would pass vacuously"
)

local hijackers = {}
for _, path in ipairs(health_files) do
  if path:find("/lua/codriver/vendor/", 1, true) then
    table.insert(hijackers, path)
  end
end
harness.expect(
  #hijackers == 0,
  "a vendored file answers :checkhealth claudecode: %s — vendor-sync.sh's health.lua rename has regressed",
  table.concat(hijackers, ", ")
)

-- -------------------------------------------------------- codriver still works ---
-- The other half of coexistence: the rival on runtimepath must not degrade
-- codriver either.

local session = require("codriver.session")
local started = session.start()

harness.expect(not started.error, "session.start() failed with the fixture loaded: " .. tostring(started.error))
harness.expect(type(started.port) == "number", "session.start() reported no port with the fixture loaded")
harness.expect_eq(#harness.lock_files(), 1, "expected exactly one lockfile with the fixture loaded")

session.stop()
harness.expect_eq(#harness.lock_files(), 0, "lockfiles left behind")

harness.ok("the fixture keeps its modules, commands, shutdown autocmd and checkhealth section; codriver keeps its own")
