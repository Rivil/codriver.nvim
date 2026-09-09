require("tests.busted_setup")

local claude_settings = require("codriver.hook.claude_settings")

-- merge()/encode() are pure table transforms with no vim.* surface, which is
-- why they live in the busted lane rather than tests/nvim/ — install()'s real
-- filesystem I/O is covered headlessly instead.

local OLD_COMMAND = "nvim --clean -l /old/root/scripts/codriver-hook.lua"
local NEW_COMMAND = "nvim --clean -l /new/root/scripts/codriver-hook.lua"

local function codriver_entries(doc)
  local matches = {}
  for _, entry in ipairs(doc.hooks.PreToolUse) do
    for _, h in ipairs(entry.hooks) do
      if type(h.command) == "string" and h.command:find("codriver%-hook%.lua") then
        table.insert(matches, entry)
        break
      end
    end
  end
  return matches
end

describe("codriver.hook.claude_settings", function()
  describe("merge", function()
    it("preserves everything it did not write, element-for-element and in order", function()
      local existing = {
        model = "claude-sonnet-5",
        permissions = {
          allow = { "WebSearch", "Bash(git status)", "Bash(git log *)" },
        },
      }

      local merged = claude_settings.merge(existing, NEW_COMMAND)

      assert.equal("claude-sonnet-5", merged.model)
      assert.same({ "WebSearch", "Bash(git status)", "Bash(git log *)" }, merged.permissions.allow)
    end)

    it("is idempotent — merging twice yields exactly one codriver entry", function()
      local once = claude_settings.merge(nil, NEW_COMMAND)
      local twice = claude_settings.merge(once, NEW_COMMAND)

      assert.equal(1, #codriver_entries(twice))
    end)

    it("replaces a stale codriver entry rather than adding beside it", function()
      local existing = claude_settings.merge(nil, OLD_COMMAND)

      local merged = claude_settings.merge(existing, NEW_COMMAND)

      assert.equal(1, #codriver_entries(merged))
      local hooks = merged.hooks.PreToolUse[1].hooks
      assert.equal(NEW_COMMAND, hooks[1].command)
      for _, entry in ipairs(merged.hooks.PreToolUse) do
        for _, h in ipairs(entry.hooks) do
          assert.is_not.equal(OLD_COMMAND, h.command)
        end
      end
    end)

    it("leaves unrelated hooks untouched", function()
      local existing = {
        hooks = {
          PreToolUse = {
            { matcher = "Bash", hooks = { { type = "command", command = "some-other-tool" } } },
          },
          PostToolUse = {
            { matcher = "*", hooks = { { type = "command", command = "audit-log" } } },
          },
        },
      }

      local merged = claude_settings.merge(existing, NEW_COMMAND)

      assert.equal(2, #merged.hooks.PreToolUse)
      assert.equal("some-other-tool", merged.hooks.PreToolUse[1].hooks[1].command)
      assert.same(existing.hooks.PostToolUse, merged.hooks.PostToolUse)
    end)

    it("registers the matcher as the literal wildcard", function()
      local merged = claude_settings.merge(nil, NEW_COMMAND)

      assert.equal("*", merged.hooks.PreToolUse[1].matcher)
    end)
  end)

  describe("encode", function()
    it("is byte-stable across repeated encodes of the same document", function()
      local doc = claude_settings.merge({ permissions = { allow = { "WebSearch" } } }, NEW_COMMAND)

      local first = claude_settings.encode(doc)
      local second = claude_settings.encode(doc)

      assert.equal(first, second)
    end)

    it("renders an empty permissions.allow as an array, not an object", function()
      local encoded = claude_settings.encode({ permissions = { allow = {} } })

      assert.is_truthy(encoded:find('"allow": []', 1, true))
    end)

    it("renders an empty hooks.PreToolUse as an array, not an object", function()
      local encoded = claude_settings.encode({ hooks = { PreToolUse = {} } })

      assert.is_truthy(encoded:find('"PreToolUse": []', 1, true))
    end)

    it("does not fabricate a permissions key when the document has none", function()
      local encoded = claude_settings.encode({ model = "claude-sonnet-5" })

      assert.is_falsy(encoded:find('"permissions"', 1, true))
    end)

    it("produces the same key order and indent on every encode of a merged doc", function()
      local doc = claude_settings.merge(nil, NEW_COMMAND)

      local encoded = claude_settings.encode(doc)

      assert.is_truthy(encoded:find('"hooks": {', 1, true))
      assert.is_truthy(encoded:find("  \"hooks\"", 1, true), "top-level keys are indented by exactly one level")
    end)
  end)
end)
