require("tests.busted_setup")

local config = require("codriver.config")

---The single warning the resolver emitted, or nil.
---@return table|nil
local function only_notification()
  local notifications = _G.vim._notifications
  if #notifications ~= 1 then
    return nil
  end
  return notifications[1]
end

-- NOTE: these specs run under bare LuaJIT against the deliberately tiny vim
-- stub in tests/busted_setup.lua. If config.lua ever reaches for a wider vim
-- API, the failure here is an index-of-nil, and the fix is to stop reaching —
-- not to grow the stub. Code that needs real Neovim belongs in tests/nvim/.
describe("codriver.config", function()
  before_each(function()
    _G.reset_vim_stub()
  end)

  describe("the option boundary", function()
    it("rejects an unknown top-level key, naming it", function()
      local ok, err = pcall(config.resolve, { auto_strt = true })

      assert.is_false(ok, "a typo must not reach the vendored layer as a half-understood table")
      assert.is_truthy(tostring(err):find("auto_strt", 1, true), "the error must name the offending key")
    end)

    it("rejects a vendored key placed at the top level", function()
      -- The whole point of the nesting: `terminal` is the vendored layer's, so
      -- at the top level it is a mistake, not a codriver option.
      local ok, err = pcall(config.resolve, { terminal = { provider = "snacks" } })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("terminal", 1, true))
      assert.is_truthy(tostring(err):find("claudecode", 1, true), "the error must point at the nesting")
    end)

    it("names every unknown key, not just the first", function()
      local ok, err = pcall(config.resolve, { nope = 1, also_nope = 2 })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("nope", 1, true))
      assert.is_truthy(tostring(err):find("also_nope", 1, true))
    end)

    it("rejects a non-boolean auto_start and a non-table claudecode", function()
      assert.has_error(function()
        config.resolve({ auto_start = "yes" })
      end)
      assert.has_error(function()
        config.resolve({ claudecode = "log_level=debug" })
      end)
    end)

    it("accepts nil and an empty table", function()
      assert.is_table(config.resolve().codriver)
      assert.is_table(config.resolve({}).claudecode)
    end)
  end)

  describe("explicit start", function()
    it("keeps the vendored auto_start off by default", function()
      -- Nothing may listen on a port or write a lockfile until a human asks.
      assert.is_false(config.resolve({}).claudecode.auto_start)
      assert.is_false(config.resolve({}).codriver.auto_start)
    end)

    it("forces the vendored auto_start off even when set, and says so once", function()
      local resolved = config.resolve({ claudecode = { auto_start = true } })

      assert.is_false(resolved.claudecode.auto_start, "the locked decision is not overridable from below")

      local warning = only_notification()
      assert.is_truthy(warning, "overriding it silently would look like it worked")
      assert.are.equal(vim.log.levels.WARN, warning.level)
      assert.is_truthy(warning.msg:find("auto_start", 1, true), "the warning must name the option to use instead")
    end)

    it("does not forward the codriver opt-in down to the vendored layer", function()
      -- The vendored setup() starts its server before codriver has registered a
      -- command; launch-time start is the wrapper's job, in its own order.
      local resolved = config.resolve({ auto_start = true })

      assert.is_true(resolved.codriver.auto_start)
      assert.is_false(resolved.claudecode.auto_start)
    end)
  end)

  describe("defaults codriver has an opinion about", function()
    it("tracks the selection by default", function()
      -- Claude reading the buffer and the visual selection hangs off this.
      assert.is_true(config.resolve({}).claudecode.track_selection)
      assert.are.equal(0, #_G.vim._notifications, "the default must not warn")
    end)

    it("passes an explicit track_selection = false through, with a warning", function()
      local resolved = config.resolve({ claudecode = { track_selection = false } })

      assert.is_false(resolved.claudecode.track_selection, "it is a supported opt-out, not a forced key")

      local warning = only_notification()
      assert.is_truthy(warning, "silently dropping the selection surface would be a mystery to debug")
      assert.are.equal(vim.log.levels.WARN, warning.level)
      assert.is_truthy(warning.msg:find("track_selection", 1, true))
    end)

    it("defaults the terminal provider to auto", function()
      assert.are.equal("auto", config.resolve({}).claudecode.terminal.provider)
    end)

    it("lets a nested terminal provider survive the merge", function()
      local resolved = config.resolve({ claudecode = { terminal = { provider = "snacks" } } })

      assert.are.equal("snacks", resolved.claudecode.terminal.provider)
    end)

    it("merges deeply rather than replacing a nested table wholesale", function()
      local resolved = config.resolve({ claudecode = { terminal = { provider_opts = { x = 1 } } } })

      assert.are.equal("auto", resolved.claudecode.terminal.provider, "a sibling key must survive")
      assert.are.equal(1, resolved.claudecode.terminal.provider_opts.x)
    end)

    it("passes unopinionated vendored keys through untouched", function()
      local resolved = config.resolve({ claudecode = { log_level = "debug", port_range = { min = 1, max = 2 } } })

      assert.are.equal("debug", resolved.claudecode.log_level)
      assert.are.equal(1, resolved.claudecode.port_range.min)
    end)

    it("shares function values by reference so a table provider still works", function()
      local provider = {
        open = function() end,
      }
      local resolved = config.resolve({ claudecode = { terminal = { provider = provider } } })

      assert.are.equal(provider.open, resolved.claudecode.terminal.provider.open)
    end)
  end)

  describe("isolation from the caller's table", function()
    it("does not let the result alias the caller's nested tables", function()
      -- The vendored setup() mutates what it is handed, and a lazy.nvim `opts`
      -- table is reused across reloads. Aliasing would make the second reload
      -- see the first one's mutations.
      local opts = { claudecode = { terminal = { provider = "auto" } } }
      local resolved = config.resolve(opts)

      resolved.claudecode.terminal.provider = "snacks"

      assert.are.equal("auto", opts.claudecode.terminal.provider)
    end)

    it("does not let a later mutation of the caller's table reach the result", function()
      local opts = { claudecode = { log_level = "info" } }
      local resolved = config.resolve(opts)

      opts.claudecode.log_level = "trace"

      assert.are.equal("info", resolved.claudecode.log_level)
    end)

    it("does not let one resolve() leak into the next", function()
      local first = config.resolve({})
      first.claudecode.terminal.provider = "snacks"

      assert.are.equal("auto", config.resolve({}).claudecode.terminal.provider, "the defaults were mutated")
    end)
  end)

  describe("the launch channel", function()
    local CHANNEL = { state_file = "/state/codriver-42.json", nvim_address = "/tmp/nvim.42.0.sock" }

    it("injects the channel into claudecode.env without clobbering the user's own entries", function()
      local resolved = config.resolve({ claudecode = { env = { FOO = "1" } } }, CHANNEL)

      assert.are.equal("1", resolved.claudecode.env.FOO, "codriver adds keys, it does not own the table")
      assert.are.equal(CHANNEL.state_file, resolved.claudecode.env.CODRIVER_STATE_FILE)
      assert.are.equal(CHANNEL.nvim_address, resolved.claudecode.env.CODRIVER_NVIM_ADDRESS)
    end)

    it("forces its own keys even when the user set one, warning exactly once", function()
      local resolved = config.resolve({ claudecode = { env = { CODRIVER_STATE_FILE = "/evil/path" } } }, CHANNEL)

      assert.are.equal(
        CHANNEL.state_file,
        resolved.claudecode.env.CODRIVER_STATE_FILE,
        "role state must not become user-writable"
      )
      assert.are.equal(CHANNEL.nvim_address, resolved.claudecode.env.CODRIVER_NVIM_ADDRESS)

      local warning = only_notification()
      assert.is_truthy(warning, "silently overriding it would hide that role state is not user-controllable")
      assert.are.equal(vim.log.levels.WARN, warning.level)
      assert.is_truthy(warning.msg:find("CODRIVER_STATE_FILE", 1, true), "the warning must name the ignored key")
    end)

    it("omits both keys entirely when no channel is supplied", function()
      local resolved = config.resolve({})

      assert.is_nil(
        resolved.claudecode.env.CODRIVER_STATE_FILE,
        "an empty value would read downstream as a live session with an unreadable file"
      )
      assert.is_nil(resolved.claudecode.env.CODRIVER_NVIM_ADDRESS)
    end)

    it("never reaches for vim.fn to compute the channel itself", function()
      -- The bare stub carries no vim.fn table at all -- resolve would error the
      -- instant it tried stdpath() or serverstart() rather than taking the
      -- channel as a parameter. Ensuring and publishing the channel before
      -- resolve is called is t-8's job, not this module's.
      assert.has_no.errors(function()
        config.resolve({}, CHANNEL)
      end)
    end)

    it("stringifies every channel value before it reaches env", function()
      local resolved = config.resolve({}, { state_file = "/s", nvim_address = 4321 })

      assert.are.equal(
        "4321",
        resolved.claudecode.env.CODRIVER_NVIM_ADDRESS,
        "a non-string value in env takes down the vendored config.apply assert"
      )
    end)
  end)

  describe("the test_command option", function()
    it("rejects a non-string test_command", function()
      assert.has_error(function()
        config.resolve({ test_command = 42 })
      end)
    end)

    it("still rejects a misspelled key as unknown", function()
      local ok, err = pcall(config.resolve, { test_commnd = "mise run test" })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("test_commnd", 1, true))
    end)

    it("defaults to nil", function()
      assert.is_nil(config.resolve({}).codriver.test_command)
    end)

    it("surfaces under .codriver, never .claudecode", function()
      local resolved = config.resolve({ test_command = "mise run test" })

      assert.are.equal("mise run test", resolved.codriver.test_command)
      assert.is_nil(resolved.claudecode.test_command)
    end)
  end)

  describe("the bash_allow option", function()
    it("resolves heads and git_subcommands through unchanged", function()
      local bash_allow = { heads = { "foo" }, git_subcommands = { "stash" } }
      local resolved = config.resolve({ bash_allow = bash_allow })

      assert.are.same(bash_allow, resolved.codriver.bash_allow)
    end)

    it("rejects a non-table bash_allow, naming it", function()
      local ok, err = pcall(config.resolve, { bash_allow = "nope" })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("bash_allow", 1, true))
    end)

    it("rejects a non-table bash_allow.heads, naming it", function()
      local ok, err = pcall(config.resolve, { bash_allow = { heads = "nope" } })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("bash_allow.heads", 1, true))
    end)

    it("rejects a non-string entry inside bash_allow.heads, naming the offending field", function()
      local ok, err = pcall(config.resolve, { bash_allow = { heads = { 42 } } })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("bash_allow.heads", 1, true))
    end)

    it("rejects a non-string entry inside bash_allow.git_subcommands, naming the offending field", function()
      local ok, err = pcall(config.resolve, { bash_allow = { git_subcommands = { true } } })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("bash_allow.git_subcommands", 1, true))
    end)

    it("rejects an empty-string entry inside bash_allow.heads", function()
      local ok, err = pcall(config.resolve, { bash_allow = { heads = { "" } } })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("bash_allow.heads", 1, true))
    end)

    it("rejects an empty-string entry inside bash_allow.git_subcommands", function()
      local ok, err = pcall(config.resolve, { bash_allow = { git_subcommands = { "" } } })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("bash_allow.git_subcommands", 1, true))
    end)

    it("defaults to nil", function()
      assert.is_nil(config.resolve({}).codriver.bash_allow)
    end)
  end)
end)
