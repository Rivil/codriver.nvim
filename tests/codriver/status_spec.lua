require("tests.busted_setup")

local status = require("codriver.status")

---The three states, as a real session reports them.
local function snapshot(overrides)
  local base = {
    listening = false,
    port = nil,
    connected = false,
    client_count = 0,
    lockfile = "/tmp/claude/ide/12345.lock",
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

local NO_SESSION = snapshot({})
local LISTENING = snapshot({ listening = true, port = 12345 })
local CONNECTED = snapshot({ listening = true, port = 12345, connected = true, client_count = 1 })

describe("codriver.status", function()
  describe("describe", function()
    it("says three different things about the three states", function()
      local none = status.describe(NO_SESSION)
      local listening = status.describe(LISTENING)
      local connected = status.describe(CONNECTED)

      assert.are_not.equal(none, listening)
      assert.are_not.equal(listening, connected)
      assert.are_not.equal(none, connected)
    end)

    it("does not let the listening line read as connected", function()
      -- The whole point of c-4. A session can sit listening for as long as you
      -- like with no Claude attached, and that is the state you are in when a
      -- send silently queues instead of arriving.
      local listening = status.describe(LISTENING)
      local connected = status.describe(CONNECTED)

      assert.is_truthy(connected:find("Claude attached", 1, true))
      assert.is_nil(listening:find("Claude attached", 1, true), "the not-connected line must fail the connected match")
      assert.is_truthy(listening:find("waiting for Claude", 1, true))
      assert.is_nil(connected:find("waiting for Claude", 1, true))
    end)

    it("names the port, so the answer is useful without a health split", function()
      assert.is_truthy(status.describe(LISTENING):find("12345", 1, true))
      assert.is_truthy(status.describe(CONNECTED):find("12345", 1, true))
    end)

    it("never infers connected from a client count", function()
      -- The vendored is_claude_connected() falls back to client_count > 0 when
      -- it has no client info, so an un-upgraded TCP connection reads as
      -- Claude. Nothing here may repeat that: `connected` is the only input.
      local tcp_only = snapshot({ listening = true, port = 12345, connected = false, client_count = 1 })

      local line = status.describe(tcp_only)

      assert.is_nil(line:find("Claude attached", 1, true))
      assert.is_truthy(line:find("waiting for Claude", 1, true))
    end)

    it("counts attached clients, in the plural when there are several", function()
      assert.is_truthy(status.describe(CONNECTED):find("(1 client)", 1, true))

      local several = snapshot({ listening = true, port = 12345, connected = true, client_count = 2 })
      assert.is_truthy(status.describe(several):find("(2 clients)", 1, true))
    end)

    it("points at the command that opens a session when there is none", function()
      local line = status.describe(NO_SESSION)

      assert.is_truthy(line:find(":CodriverStart", 1, true))
      assert.is_nil(line:find("ClaudeCode", 1, true), "the advice must name a command codriver actually registers")
    end)

    it("flags a listening server whose lockfile has gone", function()
      -- Claude finds a session through the lockfile. Without one, a perfectly
      -- healthy server is invisible, and that explains why nothing attaches.
      -- Built literally: `lockfile = nil` in an override table is an absent
      -- key, not an instruction to remove one.
      local orphaned = { listening = true, port = 12345, connected = false, client_count = 0 }

      assert.is_truthy(status.describe(orphaned):find("lockfile missing", 1, true))
      assert.is_nil(status.describe(LISTENING):find("lockfile missing", 1, true))
    end)

    it("survives a snapshot with no port rather than erroring mid-status", function()
      local line = status.describe(snapshot({ listening = true, port = nil }))

      assert.is_truthy(line:find("port unknown", 1, true))
    end)

    it("treats a missing snapshot as no session", function()
      assert.is_truthy(status.describe(nil):find("no session", 1, true))
    end)
  end)
end)
