-- setup(): publish role, listen, clean up on exit — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/hook_publish_check.lua
--
-- Real Neovim (0.12.x, pinned in mise.toml) auto-listens on a default pipe
-- before any script runs, so v:servername is never actually empty in this
-- harness the way t-8's plan assumed. `vim.v` is an ordinary Lua table under
-- the hood, though, so the empty-servername branch is exercised directly: a
-- metatable proxy overrides `servername` alone and forwards every other field
-- (vim.v.shell_error, vim.v.event, ...) to the real vim.v, which the vendored
-- layer reads during its own setup.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local role = require("codriver.role")
local session = require("codriver.session")
local state = require("codriver.hook.state")

local TEST_COMMAND = "mise run test"
local BASH_ALLOW = { heads = { "foo" }, git_subcommands = { "stash" } }
local WRITE_ALLOW = { "notes" }

-- ---------------------------------------------------- forced empty servername ---

local real_v = vim.v
vim.v = setmetatable({ servername = "" }, { __index = real_v })

---Every provider call that puts something on screen, alongside the env the
---CLI would have inherited — the only way to observe what setup() actually put
---in `resolved.claudecode.env`, short of exporting `resolved` itself.
---@type { fn: string, env: table }[]
local calls = {}

---@param name string
---@return fun(cmd: any, env: any)
local function record(name)
  return function(cmd, env)
    table.insert(calls, { fn = name, env = type(env) == "table" and env or {} })
  end
end

local provider = {
  -- Not recorded: the vendored setup calls provider.setup() once as part of
  -- initializing, before :Codriver runs at all — recording it would make the
  -- "exactly one terminal call" count below off by one for a reason that has
  -- nothing to do with the terminal the command actually opened.
  setup = function() end,
  open = record("open"),
  close = function() end,
  simple_toggle = record("simple_toggle"),
  focus_toggle = function() end,
  get_active_bufnr = function()
    return nil
  end,
  is_available = function()
    return true
  end,
}

local codriver = require("codriver")
codriver.setup({
  test_command = TEST_COMMAND,
  bash_allow = BASH_ALLOW,
  write_allow = WRITE_ALLOW,
  claudecode = { terminal = { provider = provider } },
})

-- vim.v is restored immediately after the call whose branch it was steering —
-- everything below runs against the real vim.v again.
vim.v = real_v

-- 7. Publish happens before the vendored setup runs, not deferred to the first
-- command: the record is already a readable navigator record the instant
-- setup() returns.
local immediately = state.read(state.path())
harness.expect(immediately ~= nil, "no state record exists immediately after setup() returned")
harness.expect_eq(immediately.role, "navigator", "setup() must publish the role before returning, not on first use")
harness.expect_eq(immediately.test_command, TEST_COMMAND, "setup() must publish the resolved test_command")
harness.expect_eq(
  immediately.bash_allow and immediately.bash_allow.heads and immediately.bash_allow.heads[1],
  "foo",
  "setup() must publish the resolved bash_allow"
)
harness.expect_eq(
  immediately.write_allow and immediately.write_allow[1],
  "notes",
  "setup() must publish the resolved write_allow"
)

-- setup() must also expose the resolved config on the module itself, not only
-- through the state file — health.lua reads it directly.
harness.expect_eq(
  codriver.config and codriver.config.bash_allow and codriver.config.bash_allow.heads and codriver.config.bash_allow.heads[1],
  "foo",
  "setup() must expose the resolved bash_allow on the codriver module for health.lua to read"
)
harness.expect_eq(
  codriver.config and codriver.config.write_allow and codriver.config.write_allow[1],
  "notes",
  "setup() must expose the resolved write_allow on the codriver module for health.lua to read"
)

-- 4 + 5. Drive a real terminal-opening command to observe the environment the
-- CLI would inherit: the address setup() resolved when v:servername read
-- empty, and the state file path — both asserted live, not recomputed
-- independently, because recomputing them would prove nothing about what
-- setup() actually did.
vim.cmd("Codriver")

harness.expect_eq(#calls, 1, "expected exactly one terminal call from a cold :Codriver")
local env = calls[1].env

harness.expect(
  type(env.CODRIVER_NVIM_ADDRESS) == "string" and env.CODRIVER_NVIM_ADDRESS ~= "",
  "CODRIVER_NVIM_ADDRESS was absent from the CLI's environment — v:servername read empty and serverstart() "
    .. "was not called, so every hook refusal has nowhere to notify"
)

local chan = vim.fn.sockconnect("pipe", env.CODRIVER_NVIM_ADDRESS, vim.empty_dict())
harness.expect(chan > 0, "CODRIVER_NVIM_ADDRESS %s does not accept a connection", env.CODRIVER_NVIM_ADDRESS)
if chan > 0 then
  vim.fn.chanclose(chan)
end

harness.expect_eq(
  env.CODRIVER_STATE_FILE,
  state.path(),
  "CODRIVER_STATE_FILE handed to the CLI is not the path codriver itself reads and writes"
)
local via_env = state.read(env.CODRIVER_STATE_FILE)
harness.expect(via_env ~= nil, "CODRIVER_STATE_FILE names a path that is not a readable record")
harness.expect_eq(via_env.role, "navigator", "the record named by CODRIVER_STATE_FILE must read navigator")

harness.expect(session.stop().stopped, "stop() failed after the cold :Codriver")

-- 1 + 2. The on_change listener is what makes c-6 live rather than
-- launch-fixed, and the republish must not drop the test_command it was not
-- asked to change.
role.set("driver")
local after_flip = state.read(state.path())
harness.expect_eq(after_flip.role, "driver", "role.set(\"driver\") after setup() left the state file reading navigator")
harness.expect_eq(
  after_flip.test_command,
  TEST_COMMAND,
  "the on_change republish dropped test_command — a field it was not asked to change"
)
harness.expect_eq(
  after_flip.bash_allow and after_flip.bash_allow.heads and after_flip.bash_allow.heads[1],
  "foo",
  "the on_change republish dropped bash_allow — a field it was not asked to change"
)
harness.expect_eq(
  after_flip.write_allow and after_flip.write_allow[1],
  "notes",
  "the on_change republish dropped write_allow — a field it was not asked to change"
)

role.set("navigator")
harness.expect_eq(state.read(state.path()).role, "navigator", "role.set(\"navigator\") did not republish")

-- 6. A second setup() must not register a second listener: spy on the write
-- primitive one role flip goes through (the same technique hook_state_check.lua
-- uses for publish()'s atomicity), and require exactly one write for one flip.
require("codriver").setup({ test_command = TEST_COMMAND })

local real_fs_rename = vim.uv.fs_rename
local renames = 0
vim.uv.fs_rename = function(...)
  renames = renames + 1
  return real_fs_rename(...)
end

role.set("driver")

vim.uv.fs_rename = real_fs_rename
harness.expect_eq(
  renames,
  1,
  "one role flip triggered "
    .. renames
    .. " writes to the state file — setup() is not re-entrant, and registered a second role listener"
)

role.set("navigator")

-- 3. The state file must not outlive Neovim: a child that sets up and exits
-- must leave nothing behind, asserted for both a normal :qa and a :cquit,
-- since a real bug here is exactly the kind that differs between the two.
local function exit_leaves_no_state(exit_command, label)
  local child_script = harness.sandbox_root .. "/hook_publish_child_" .. label .. ".lua"
  harness.write(
    child_script,
    ([[
vim.opt.runtimepath:prepend(%q)
vim.opt.swapfile = false

require("codriver").setup({ test_command = %q })

local state = require("codriver.hook.state")
print("state_path=" .. state.path())

if state.read(state.path()) == nil then
  io.stderr:write("child: setup() did not publish a readable record\n")
  vim.cmd("cquit 1")
end

%s
]]):format(harness.repo_root, TEST_COMMAND, exit_command)
  )

  local result = harness.run({ "nvim", "--clean", "--headless", "-l", child_script }, {
    env = { CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR },
  })

  local output = (result.stdout or "") .. (result.stderr or "")
  local child_path = output:match("state_path=(%S+)")
  harness.expect(child_path ~= nil, "the %s child never reported its state path:\n%s", label, output)

  harness.expect_eq(
    vim.fn.filereadable(child_path),
    0,
    ("the %s child left its state record behind at %s — the next bare `claude` run in this repo would be governed "
      .. "by a session that no longer exists"):format(label, child_path)
  )
end

exit_leaves_no_state("vim.cmd(\"qa\")", "qa")
exit_leaves_no_state("vim.cmd(\"cquit 1\")", "cquit")

harness.ok(
  "setup() publishes a readable navigator record with a connectable address before the vendored setup runs, "
    .. "exposes the resolved bash_allow on the module itself, role flips republish live without dropping "
    .. "test_command or bash_allow, a second setup() does not double-listen, and the record does not outlive "
    .. "Neovim on :qa or :cquit"
)
