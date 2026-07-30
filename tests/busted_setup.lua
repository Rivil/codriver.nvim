-- Test setup for busted.
--
-- Busted runs under bare LuaJIT, with no Neovim around it, so anything the code
-- under test touches on the `vim` global has to be stubbed here. This stub is
-- deliberately tiny: it covers exactly what the pure-Lua wrapper modules use,
-- and nothing more.
--
-- It is NOT a general-purpose Neovim mock, and it must not grow into one. Code
-- that needs a real vim API should be tested in headless Neovim instead — see
-- tests/nvim/ and `mise run test-nvim`. Upstream claudecode.nvim maintains a
-- full vim mock for its own suite; we deliberately did not vendor it, because
-- the vendored protocol layer is tested against real Neovim rather than a
-- reimplementation of it.

_G.assert = require("luassert")

if not _G.vim then
  _G.vim = {
    log = { levels = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, OFF = 5 } },

    -- Captured rather than printed, so a test can assert on what was notified.
    notify = function(msg, level)
      table.insert(_G.vim._notifications, { msg = msg, level = level })
    end,

    inspect = function(value)
      if type(value) == "string" then
        return ('"%s"'):format(value)
      end
      return tostring(value)
    end,

    _notifications = {},
  }
end

---Clear state that leaks between tests.
_G.reset_vim_stub = function()
  _G.vim._notifications = {}
end
