-- Headless launch-time enforcement check — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/enforcement_launch_check.lua
--
-- The only check in this directory where the GENERATED registration is what
-- enforces: every other check invokes the hook script by a path it composed
-- itself. This one drives a real `:CodriverStart` against a capture terminal
-- provider, reads back whatever `.claude/settings.local.json` codriver
-- actually wrote, and runs THAT command against a live navigator session to
-- prove it denies — nothing here is asserted from the source, only from what
-- landed on disk and what running it does.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local state = require("codriver.hook.state")

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

local REAL_SETTINGS = harness.repo_root .. "/.claude/settings.local.json"
local function snapshot_real_settings()
  if vim.fn.filereadable(REAL_SETTINGS) == 1 then
    return table.concat(vim.fn.readfile(REAL_SETTINGS), "\n")
  end
  return nil
end
local real_settings_before = snapshot_real_settings()

-- Moved before setup() runs at all: ensure_server() reads vim.fn.getcwd()
-- itself, and this check must never arm the developer's own repository.
local PROJECT = harness.sandbox_root .. "/project"
vim.fn.mkdir(PROJECT, "p")
vim.fn.chdir(PROJECT)

local SETTINGS_PATH = PROJECT .. "/.claude/settings.local.json"

-- 2 + 5. The project starts with a settings file that has nothing to do with
-- codriver: generic permissions and a foreign PostToolUse hook, no PreToolUse
-- block at all. Nobody hand-wires codriver's own registration — arm() has to
-- generate the whole thing from nothing while leaving the rest alone.
harness.write(
  SETTINGS_PATH,
  vim.json.encode({
    permissions = { allow = { "Bash(git *)" } },
    hooks = {
      PostToolUse = {
        { matcher = "*", hooks = { { type = "command", command = "some-foreign-tool" } } },
      },
    },
  })
)

---True once `.claude/settings.local.json` carries a codriver PreToolUse
---entry — read fresh every call, never cached, so a check that calls this
---from inside the terminal-open handler observes the real state at that
---exact moment.
---@return boolean
local function is_armed()
  if vim.fn.filereadable(SETTINGS_PATH) ~= 1 then
    return false
  end
  local ok, doc = pcall(vim.json.decode, table.concat(vim.fn.readfile(SETTINGS_PATH), "\n"))
  if not ok or type(doc) ~= "table" or type(doc.hooks) ~= "table" then
    return false
  end
  for _, entry in ipairs(doc.hooks.PreToolUse or {}) do
    for _, h in ipairs((type(entry) == "table" and entry.hooks) or {}) do
      if type(h) == "table" and type(h.command) == "string" and h.command:find("codriver%-hook%.lua") then
        return true
      end
    end
  end
  return false
end

-- 1 + 3. A capture terminal provider: for each call, records whether
-- enforcement was already live at that exact moment and the env the CLI
-- would actually launch with — late arming cannot be masked by a later read.
local calls = {}
local provider = {
  setup = function() end,
  open = function(_cmd, env)
    table.insert(calls, { armed_at_open = is_armed(), env = type(env) == "table" and env or {} })
  end,
  close = function() end,
  simple_toggle = function() end,
  focus_toggle = function() end,
  get_active_bufnr = function()
    return nil
  end,
  is_available = function()
    return true
  end,
}

require("codriver").setup({
  test_command = "mise run test",
  claudecode = { terminal = { provider = provider } },
})

vim.cmd("CodriverStart")

harness.expect_eq(#calls, 1, "expected exactly one terminal call from a cold :CodriverStart")

-- 1. Registration must be in place before the CLI launches, not after.
harness.expect(
  calls[1].armed_at_open,
  "the terminal opened while .claude/settings.local.json still carried no codriver PreToolUse entry"
)

-- 3. The launch env carries a working channel: a readable navigator record
-- and an address that actually accepts a connection.
local env = calls[1].env
harness.expect(
  type(env.CODRIVER_STATE_FILE) == "string" and env.CODRIVER_STATE_FILE ~= "",
  "CODRIVER_STATE_FILE was absent from the launch env"
)
local record = state.read(env.CODRIVER_STATE_FILE)
harness.expect(record ~= nil, "CODRIVER_STATE_FILE names a path that is not a readable record")
harness.expect_eq(record.role, "navigator", "the record named by CODRIVER_STATE_FILE must read navigator")

harness.expect(
  type(env.CODRIVER_NVIM_ADDRESS) == "string" and env.CODRIVER_NVIM_ADDRESS ~= "",
  "CODRIVER_NVIM_ADDRESS was absent from the launch env"
)
local chan = vim.fn.sockconnect("pipe", env.CODRIVER_NVIM_ADDRESS, vim.empty_dict())
harness.expect(chan > 0, "CODRIVER_NVIM_ADDRESS %s does not accept a connection", env.CODRIVER_NVIM_ADDRESS)
if chan > 0 then
  vim.fn.chanclose(chan)
end

-- 2 + 5. Nothing pre-existing was destroyed on the way to arming.
local doc = vim.json.decode(table.concat(vim.fn.readfile(SETTINGS_PATH), "\n"))
harness.expect(
  type(doc.permissions) == "table" and type(doc.permissions.allow) == "table",
  "the seeded permissions.allow array did not survive"
)
harness.expect_contains(vim.json.encode(doc.permissions.allow), "Bash(git *)", "the seeded permissions entry was lost")
harness.expect_eq(#(doc.hooks.PostToolUse or {}), 1, "the foreign PostToolUse hook did not survive")
harness.expect_eq(
  doc.hooks.PostToolUse[1].hooks[1].command,
  "some-foreign-tool",
  "the foreign PostToolUse hook was altered rather than left alone"
)
harness.expect_eq(#(doc.hooks.PreToolUse or {}), 1, "expected exactly one generated codriver PreToolUse entry")

-- 4. The GENERATED registration is what enforces — run the exact command
-- read out of the settings file, not a path this check composed itself.
local command = doc.hooks.PreToolUse[1].hooks[1].command
local script_path = command:match("^nvim %-%-clean %-l (.+)$")
harness.expect(script_path ~= nil, "could not parse a script path out of the generated command %q", command)
harness.expect_eq(
  vim.fn.filereadable(script_path),
  1,
  "the generated hook script does not exist at " .. tostring(script_path)
)

local run_result = harness.run({ "nvim", "--clean", "-l", script_path }, {
  env = { CODRIVER_STATE_FILE = env.CODRIVER_STATE_FILE },
  stdin = vim.json.encode({ hook_event_name = "PreToolUse", tool_name = "Edit", tool_input = { file_path = "x" } }),
  timeout = 10000,
})
harness.expect_eq(run_result.code, 0, "the generated command failed to run: " .. tostring(run_result.stderr))
local decode_ok, decoded = pcall(vim.json.decode, run_result.stdout or "")
harness.expect(
  decode_ok
    and type(decoded) == "table"
    and type(decoded.hookSpecificOutput) == "table"
    and decoded.hookSpecificOutput.permissionDecision == "deny",
  "the generated registration failed to deny an Edit while navigator, got stdout: %s",
  run_result.stdout
)

vim.cmd("CodriverStop")

-- Never arms the developer's own repository, regardless of everything above
-- having run with cwd inside a temp project dir the whole time.
vim.fn.chdir(harness.repo_root)
harness.expect_eq(
  snapshot_real_settings(),
  real_settings_before,
  "this repository's own .claude/settings.local.json changed during the check"
)

harness.ok(
  "the terminal opens only once codriver's PreToolUse entry is already on disk, the launch env carries a working "
    .. "state file and RPC address, a pre-existing settings file's permissions and foreign hooks survive untouched, "
    .. "and the exact command read out of the generated registration denies a real Edit while navigator"
)
