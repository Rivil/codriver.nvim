-- Headless bash refusal and read-only survival check — run under real
-- Neovim by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/enforcement_bash_check.lua
--
-- The end-to-end half of the bash_policy lock: a shell write must be
-- refused on the same grounds as the edit tool, and real read-only work
-- must still run — not just be decided as allowed.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local state = require("codriver.hook.state")

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

local TEST_COMMAND = "mise run test"

---Publish a live navigator record under the sandboxed state home and return
---the env override that points the hook at it.
---@return table
local function live_env()
  vim.fn.delete(state.path())
  state.publish({ role = "navigator", test_command = TEST_COMMAND })
  return { CODRIVER_STATE_FILE = state.path() }
end

---@param tool string
---@param tool_input table|nil
---@return { code: integer, stdout: string, stderr: string }, table|nil
local function run(tool, tool_input)
  local result = harness.run_hook({
    hook_event_name = "PreToolUse",
    tool_name = tool,
    tool_input = tool_input,
  }, live_env())
  local decoded = nil
  if result.stdout and result.stdout ~= "" then
    local ok, parsed = pcall(vim.json.decode, result.stdout)
    decoded = ok and parsed or nil
  end
  return result, decoded
end

---@param decoded table|nil
---@return boolean
local function is_deny(decoded)
  return type(decoded) == "table"
    and type(decoded.hookSpecificOutput) == "table"
    and decoded.hookSpecificOutput.permissionDecision == "deny"
end

-- 1. A shell write is refused on the same grounds as Edit: same verdict, same
-- reason, and the target is byte-identical afterwards.
local fixture = harness.sandbox_root .. "/fixture.txt"
local fixture_content = "untouched"
harness.write(fixture, fixture_content)
local sha_before = vim.fn.sha256(fixture_content)

local edit_result, edit_decoded = run("Edit", { file_path = fixture })
harness.expect(is_deny(edit_decoded), "expected the Edit reference payload to deny, got stdout: %s", edit_result.stdout)

local bash_write_result, bash_write_decoded = run("Bash", { command = ("printf x > %s"):format(fixture) })
harness.expect(
  is_deny(bash_write_decoded),
  "expected `printf x > <fixture>` to deny under navigator, got stdout: %s",
  bash_write_result.stdout
)
harness.expect_eq(
  bash_write_decoded.hookSpecificOutput.permissionDecisionReason,
  edit_decoded.hookSpecificOutput.permissionDecisionReason,
  "a shell write must be refused on the same grounds (the same reason text) as Edit"
)
harness.expect_eq(
  vim.fn.sha256(table.concat(vim.fn.readfile(fixture), "\n")),
  sha_before,
  "a denied shell write must leave its target file byte-identical"
)

-- 2. Chaining must not defeat it end-to-end: a read-only head followed by a
-- write must still deny, and the write must never have happened.
local victim = harness.sandbox_root .. "/victim.txt"
harness.write(victim, "alive")

local chain_result, chain_decoded = run("Bash", { command = ("git status --short && rm %s"):format(victim) })
harness.expect(
  is_deny(chain_decoded),
  "expected `git status --short && rm victim.txt` to deny under navigator, got stdout: %s",
  chain_result.stdout
)
harness.expect_eq(vim.fn.filereadable(victim), 1, "victim.txt must survive a denied chained command")
harness.expect_eq(
  table.concat(vim.fn.readfile(victim), "\n"),
  "alive",
  "victim.txt must be untouched, not just present"
)

-- 3. Read-only work does not merely decide as allowed: it is actually run,
-- for real, and produces real output. `rg`, not `grep` — the bash_policy
-- allowlist (t-2) permits `rg` specifically; plain `grep` is not on it.
local search_decision = run("Bash", { command = "rg -n role lua/" })
harness.expect_eq(search_decision.code, 0, "the rg decision must exit 0")
harness.expect_eq(search_decision.stdout, "", "rg -n role lua/ must be allowed (silent) while navigator")

local search_real = harness.run({ "rg", "-n", "role", "lua/" }, { cwd = harness.repo_root })
harness.expect_eq(search_real.code, 0, "rg -n role lua/ must actually succeed when run for real")
harness.expect(search_real.stdout ~= nil and search_real.stdout ~= "", "rg -n role lua/ produced no real output")

local status_decision = run("Bash", { command = "git status --short" })
harness.expect_eq(status_decision.code, 0, "the git status decision must exit 0")
harness.expect_eq(status_decision.stdout, "", "git status --short must be allowed (silent) while navigator")

local status_real = harness.run({ "git", "status", "--short" }, { cwd = harness.repo_root })
harness.expect_eq(status_real.code, 0, "git status --short must actually succeed when run for real")

-- 4. Read-only TOOLS (not Bash) must stay allowed while navigator.
for _, tool in ipairs({ "Read", "Grep", "Glob" }) do
  local result = run(tool, { file_path = "x" })
  harness.expect_eq(result.code, 0, tool .. " must exit 0")
  harness.expect_eq(result.stdout, "", tool .. " must be allowed (silent) while navigator")
end

-- 5. The configured test_command is allowed — asserted as a decision only,
-- never by actually running it, or this check would recurse into itself.
local test_command_result = run("Bash", { command = TEST_COMMAND })
harness.expect_eq(test_command_result.code, 0, "the test_command decision must exit 0")
harness.expect_eq(test_command_result.stdout, "", "the configured test_command must be allowed while navigator")

harness.ok(
  "a shell write denies on the same grounds as Edit and leaves its target byte-identical, chaining a write behind "
    .. "a read-only head still denies and the write never happens, read-only Bash commands are not just decided "
    .. "allowed but actually run and produce real output, read-only tools stay allowed, and the configured "
    .. "test_command is allowed as a decision without ever being run"
)
