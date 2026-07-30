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
end)
