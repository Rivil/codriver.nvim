-- Auto-start off (the default) — run under real Neovim by `mise run test-nvim`:
--
--   nvim --clean --headless -l tests/nvim/autostart_off_check.lua
--
-- Codriver's premise is that nothing happens without a human at the keyboard.
-- `setup()` on its own must therefore leave no WebSocket server listening and no
-- lockfile on disk — a lockfile per Neovim instance is exactly the litter the
-- explicit-start decision exists to avoid (c-8).
--
-- Its own process, because auto-start is a property of what `setup()` did at
-- launch and there is no way back to "never started" once something has.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

require("codriver").setup({})

local status = require("codriver.vendor.claudecode.server.init").get_status()
local locks = harness.lock_files()

harness.expect_eq(status.running, false, "setup({}) started a server nobody asked for")
harness.expect_eq(#locks, 0, "setup({}) wrote a lockfile: " .. table.concat(locks, ", "))

-- The wrapper's own view has to agree, or `:CodriverStatus` would say one thing
-- while the server said another.
local snapshot = require("codriver.session").snapshot()
harness.expect_eq(snapshot.listening, false, "session.snapshot() reports listening with nothing started")
harness.expect_eq(snapshot.connected, false, "session.snapshot() reports connected with nothing started")

-- The commands still have to be there. "No session" is the default state, not a
-- half-configured plugin.
local commands = vim.api.nvim_get_commands({})
harness.expect(commands.CodriverStart, "setup({}) registered no :CodriverStart")
harness.expect(commands.CodriverStop, "setup({}) registered no :CodriverStop")

harness.ok("setup({}) leaves nothing listening and no lockfile")
