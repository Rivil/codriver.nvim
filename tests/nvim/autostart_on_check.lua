-- Auto-start on (opt-in) — run under real Neovim by `mise run test-nvim`:
--
--   nvim --clean --headless -l tests/nvim/autostart_on_check.lua
--
-- The other half of c-8: with `auto_start = true`, `setup()` opens the session
-- at launch. Its own process, because auto-start is a property of what setup()
-- did and there is no way back to "never started".
--
-- The second half of this check spawns a *child* Neovim that auto-starts and
-- then quits, because that is the only way to observe VimLeavePre. Codriver
-- renames the vendored `ClaudeCodeShutdown` augroup to `CodriverShutdown` so it
-- cannot clear a real claudecode.nvim's exit handler — and a rename that
-- accidentally became a re-create would leave the lockfile behind on exit,
-- advertising a Neovim that is no longer there.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

---A terminal provider that puts nothing on screen.
---
---`auto_start` opens a terminal along with the session, and a headless process
---has nowhere to put one — nor any business launching a real `claude`. The
---seven functions are the vendored provider contract.
---@return table
local function stub_provider()
  local provider = { calls = {} }
  for _, name in ipairs({ "setup", "open", "close", "simple_toggle", "focus_toggle" }) do
    provider[name] = function()
      table.insert(provider.calls, name)
    end
  end
  provider.get_active_bufnr = function()
    return nil
  end
  provider.is_available = function()
    return true
  end
  return provider
end

local server = require("codriver.vendor.claudecode.server.init")
local session = require("codriver.session")

local provider = stub_provider()
require("codriver").setup({
  auto_start = true,
  claudecode = { terminal = { provider = provider } },
})

local status = server.get_status()
harness.expect_eq(status.running, true, "auto_start = true did not open a session")
harness.expect(type(status.port) == "number", "the auto-started session reports no port")

local locks = harness.lock_files()
harness.expect_eq(#locks, 1, "expected exactly one lockfile, got: " .. table.concat(locks, ", "))
harness.expect_eq(
  vim.fn.fnamemodify(locks[1], ":t"),
  ("%d.lock"):format(status.port),
  "the lockfile is not named for the port that is listening"
)

-- Torn down before the child runs, so the lock directory the child leaves
-- behind is the child's alone.
harness.expect(session.stop().stopped, "stop() failed after an auto-started session")
harness.expect_eq(#harness.lock_files(), 0, "auto-started session left a lockfile after stop")

-- ----------------------------------------------------------------- child ---

local child_script = harness.sandbox_root .. "/autostart_child.lua"
harness.write(
  child_script,
  ([[
vim.opt.runtimepath:prepend(%q)
vim.opt.swapfile = false

local provider = { }
for _, name in ipairs({ "setup", "open", "close", "simple_toggle", "focus_toggle" }) do
  provider[name] = function() end
end
provider.get_active_bufnr = function() return nil end
provider.is_available = function() return true end

require("codriver").setup({
  auto_start = true,
  claudecode = { terminal = { provider = provider } },
})

local status = require("codriver.vendor.claudecode.server.init").get_status()
if not status.running then
  io.stderr:write("child: auto_start left nothing listening\n")
  vim.cmd("cquit 1")
end
print(("child listening on %%d"):format(status.port))

-- The whole point: a normal exit, with VimLeavePre free to run.
vim.cmd("qa")
]]):format(harness.repo_root)
)

local result = harness.run({ "nvim", "--clean", "--headless", "-l", child_script }, {
  env = { CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR },
})

harness.expect_eq(result.code, 0, "the child Neovim failed:\n" .. tostring(result.stderr))

-- Both streams: `print()` under `nvim --headless -l` goes to stderr, alongside
-- the messages Neovim itself emits there.
local child_output = (result.stdout or "") .. (result.stderr or "")
harness.expect_match(child_output, "child listening on %d+", "the child never reported a listening server")

local left_behind = harness.lock_files()
harness.expect_eq(
  #left_behind,
  0,
  "the child left its lockfile behind on exit — VimLeavePre did not fire, so the augroup rename to "
    .. "CodriverShutdown re-created the group instead of renaming it: "
    .. table.concat(left_behind, ", ")
)

harness.ok("auto_start = true opens a session at launch and gives its lockfile back on exit")
