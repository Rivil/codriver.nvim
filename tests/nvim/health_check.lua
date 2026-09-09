-- Health check surface — run under real Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/health_check.lua
--
-- `:checkhealth codriver` is resolved by Neovim globbing `lua/**/codriver/
-- health.lua`, so a unit test of `require("codriver.health").check()` would pass
-- happily while the command itself reported "No healthcheck found". This drives
-- the real command and reads the buffer it produces.
--
-- The session is brought up with `session.ensure_server()` rather than
-- `:CodriverStart`: the server is the part the report describes, and starting
-- through the command would also launch a real `claude` terminal in a headless
-- process.
--
-- Harness assertions are fatal, so every report is captured first and the
-- session torn down before anything is asserted.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

---Run `:checkhealth codriver` and return the rendered report.
---@return string
local function report()
  vim.cmd("checkhealth codriver")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.cmd("bwipeout!")
  return text
end

---The whole line mentioning `needle`, so a state marker can be read off it.
---@param text string
---@param needle string
---@return string|nil
local function line_with(text, needle)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:find(needle, 1, true) then
      return line
    end
  end
  return nil
end

require("codriver").setup({})

-- ---------------------------------------------------------------- gather ---

local cold = report()

local session = require("codriver.session")
local started = session.ensure_server()
local snapshot = session.snapshot()
local port, lock_path = snapshot.port, snapshot.lockfile_path

local listening = report()

-- A listening server whose lockfile has gone is invisible to Claude. It is a
-- state the report has to name, because nothing else explains why no client
-- ever attaches.
if lock_path then
  vim.fn.delete(lock_path)
end
local unlocked = report()

local stopped = session.stop()
local leftover = harness.lock_files()

-- ---------------------------------------------------------------- assert ---

harness.expect(started.started, "ensure_server() did not bring the server up: %s", tostring(started.error))
harness.expect(type(port) == "number", "no port after ensure_server()")
harness.expect(type(lock_path) == "string", "snapshot gave no lockfile path")
harness.expect(stopped.stopped, "stop() failed: %s", tostring(stopped.error))
harness.expect_eq(#leftover, 0, "lockfiles left behind after stop")

-- The command resolved to lua/codriver/health.lua at all.
harness.expect_not_contains(cold, "No healthcheck found", "checkhealth codriver did not find the report")
harness.expect_contains(cold, "codriver.nvim", "the report has no codriver section")

-- And resolved to *only* that one. `lua/**/<name>/health.lua` matches on the
-- directory, so an un-renamed vendored health.lua would add its own section.
harness.expect_not_contains(cold, "claudecode.nvim", "the vendored health module is being globbed into this report")

-- Advice may only name commands codriver actually registers.
harness.expect_contains(cold, ":CodriverStart", "the no-session report does not say how to open one")
harness.expect_not_contains(cold, ":ClaudeCodeStart", "the report advises a command codriver does not register")
harness.expect_not_contains(cold, ":ClaudeCodeStop", "the report advises a command codriver does not register")

-- Listening and connected are two states on two lines, and only one of them is
-- OK with a server up and nothing attached (c-4).
local listening_line = line_with(listening, ("Listening on port %d"):format(port))
harness.expect(listening_line, "no listening line naming port %d:\n%s", port, listening)
harness.expect_contains(listening_line, "OK", "the listening line is not reported as OK")

local connected_line = line_with(listening, "Waiting for Claude")
harness.expect(connected_line, "no connected line:\n%s", listening)
harness.expect_not_contains(connected_line, "OK", "a listening server with nothing attached must not report as OK")
harness.expect_contains(connected_line, "WARNING", "the not-connected state is not distinguishable from OK")

harness.expect_contains(listening, lock_path, "the report does not name the lockfile")
harness.expect_contains(line_with(listening, lock_path), "OK", "a present lockfile is not reported as OK")

-- Unlinked underneath a still-listening server.
harness.expect_contains(unlocked, "Lockfile missing", "an unlinked lockfile is not reported")
harness.expect_contains(unlocked, lock_path, "the missing-lockfile report does not name the path")
harness.expect_contains(line_with(unlocked, "Lockfile missing"), "ERROR", "a missing lockfile is not an error")
harness.expect_contains(unlocked, ("Listening on port %d"):format(port), "the server is still up and should say so")

-- ---------------------------------------------------------- bash allowlist ---
-- c-5: the report names the effective read-only Bash allowlist — hardcoded
-- defaults with no bash_allow configured, and this session's own additions
-- once one is.

local heads_line = line_with(cold, "Bash allowlist heads")
harness.expect(heads_line, "no Bash allowlist heads line in the cold report:\n%s", cold)
for _, head in ipairs({ "rg", "git", "ls", "cat", "head", "wc" }) do
  harness.expect_contains(heads_line, head, "heads line does not list the hardcoded default " .. head)
end

require("codriver").setup({ bash_allow = { heads = { "gh" }, git_subcommands = { "stash" } } })
local with_allow = report()

local heads_line_with_allow = line_with(with_allow, "Bash allowlist heads")
harness.expect_contains(
  heads_line_with_allow,
  "gh",
  "the heads line does not include a head added via bash_allow.heads in setup()"
)

local subcommands_line_with_allow = line_with(with_allow, "Bash allowlist git subcommands")
harness.expect_contains(
  subcommands_line_with_allow,
  "stash",
  "the git-subcommand line does not include a subcommand added via bash_allow.git_subcommands"
)

harness.ok(
  "checkhealth codriver reports listening, lockfile and connected as three separate states, and the effective "
    .. "Bash allowlist including any bash_allow additions"
)
