require("tests.busted_setup")

local notify = require("codriver.hook.notify")

---A fake monotonic clock, in milliseconds.
---
---`refused` takes its clock as a parameter precisely so this exists: the busted
---stub carries no `vim.uv`, and real elapsed time is not something a test should
---have to wait for. `c.now` is the function handed to `refused`; `c.advance`
---moves time forward by fiat.
local function clock()
  local c = { ms = 0 }
  function c.now()
    return c.ms
  end
  function c.advance(by)
    c.ms = c.ms + by
  end
  return c
end

---Everything vim.notify captured since the last reset.
local function notifications()
  return _G.vim._notifications
end

local BLOCKED = { tool = "Edit", path = "lua/x.lua" }

describe("codriver.hook.notify", function()
  before_each(function()
    _G.reset_vim_stub()
    notify._reset()
  end)

  describe("refused", function()
    it("names the blocked operation and the file it targeted", function()
      -- c-8 in one line: the user learns a write was blocked, and what it was,
      -- without leaving the editor for the Claude terminal.
      local c = clock()

      notify.refused(BLOCKED, c.now)

      assert.equal(1, #notifications())
      local sent = notifications()[1]
      assert.is_truthy(sent.msg:find("Edit", 1, true), "the notification must name the tool")
      assert.is_truthy(sent.msg:find("lua/x.lua", 1, true), "the notification must name the target file")
      assert.is_truthy(sent.msg:find("codriver", 1, true), "the notification must say who is speaking")
    end)

    it("raises the notification at WARN or above", function()
      -- A refusal at INFO scrolls past under any busy statusline. It is a block,
      -- and it has to read like one.
      local c = clock()

      notify.refused(BLOCKED, c.now)

      assert.is_true(notifications()[1].level >= _G.vim.log.levels.WARN)
    end)

    it("escapes the payload rather than formatting with it", function()
      -- The payload arrives from another process over RPC. A tool name carrying
      -- format specifiers must not reach string.format's FIRST argument, and a
      -- newline must not turn one refusal into a multi-line wall.
      local c = clock()
      local hostile = { tool = "Edit\n%s%s", path = "lua/x.lua" }

      assert.has_no.errors(function()
        notify.refused(hostile, c.now)
      end)

      assert.equal(1, #notifications())
      local msg = notifications()[1].msg
      assert.is_nil(msg:find("\n", 1, true), "one refusal is one line, whatever arrived in the payload")
    end)

    it("reports an unknown operation rather than raising on a bad payload", function()
      -- An error thrown inside nvim's RPC handler is invisible: the refusal goes
      -- unreported and the user believes the write went through. Every one of
      -- these must still produce a notification.
      local c = clock()
      local junk = {
        { payload = nil, why = "no payload at all" },
        { payload = {}, why = "empty table" },
        { payload = { path = "lua/x.lua" }, why = "missing tool" },
        { payload = { tool = 42, path = "lua/x.lua" }, why = "non-string tool" },
        { payload = { tool = "Edit" }, why = "missing path" },
        { payload = { tool = "Edit", path = {} }, why = "non-string path" },
      }

      for _, case in ipairs(junk) do
        _G.reset_vim_stub()
        notify._reset()

        assert.has_no.errors(function()
          notify.refused(case.payload, c.now)
        end, case.why)

        assert.equal(1, #notifications(), case.why .. " must still notify")
        local msg = notifications()[1].msg
        assert.is_truthy(msg:find("unknown", 1, true), case.why .. " must read as an unknown operation")
        assert.is_nil(msg:find("nil", 1, true), case.why .. " must not leak a raw nil into the message")
      end
    end)

    it("returns nothing at all", function()
      -- Not "returns nil" — returns NO values. The hook process fires this and
      -- walks away; a return value is the first step towards someone awaiting it,
      -- and c-8 must never be able to delay c-2's refusal.
      local c = clock()

      assert.equal(0, select("#", notify.refused(BLOCKED, c.now)))
    end)

    it("collapses a retry storm into one notification", function()
      -- The model retrying a blocked edit in a loop must not bury the editor.
      local c = clock()

      for _ = 1, 10 do
        notify.refused(BLOCKED, c.now)
        c.advance(50)
      end

      assert.equal(1, #notifications(), "ten identical refusals inside a second are one notification")
    end)

    it("still speaks once the quiet window has passed", function()
      -- Coalescing must not become permanent silence: a refusal a minute later
      -- is new information.
      local c = clock()

      notify.refused(BLOCKED, c.now)
      c.advance(1000)
      notify.refused(BLOCKED, c.now)

      assert.equal(2, #notifications())
    end)

    it("does not let one refusal silence a different one", function()
      -- The inverse half, and the reason coalescing is keyed on what was blocked
      -- rather than on a global gate: a crude "one notification per second"
      -- would hide a Write to a second file behind an Edit to the first, which
      -- is exactly the information c-8 exists to deliver.
      local c = clock()

      notify.refused({ tool = "Edit", path = "lua/x.lua" }, c.now)
      notify.refused({ tool = "Write", path = "lua/y.lua" }, c.now)

      assert.equal(2, #notifications())
    end)
  end)
end)
