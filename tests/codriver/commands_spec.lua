require("tests.busted_setup")

local commands = require("codriver.commands")

---Every vendored command, as of the pinned SHA in VENDOR.md. Spelled out here
---so that an upstream re-sync which adds or renames one fails this spec rather
---than silently shrinking the `:Codriver*` surface.
local VENDORED = {
  "ClaudeCode",
  "ClaudeCodeAdd",
  "ClaudeCodeClose",
  "ClaudeCodeCloseAllDiffs",
  "ClaudeCodeDiffAccept",
  "ClaudeCodeDiffDeny",
  "ClaudeCodeFocus",
  "ClaudeCodeOpen",
  "ClaudeCodeSelectModel",
  "ClaudeCodeSend",
  "ClaudeCodeSendText",
  "ClaudeCodeStart",
  "ClaudeCodeStatus",
  "ClaudeCodeStop",
  "ClaudeCodeTreeAdd",
}

---A stand-in for `vim.api`, recording what actually reached it.
local function fake_api()
  local api = {
    created = {},
    augroups = {},
  }

  api.nvim_create_user_command = function(name, handler, opts)
    table.insert(api.created, { name = name, handler = handler, opts = opts })
  end

  api.nvim_create_augroup = function(name, opts)
    table.insert(api.augroups, { name = name, opts = opts })
    return #api.augroups
  end

  return api
end

---What the vendored `_create_commands()` does, in miniature: the three
---commands whose option flags are load-bearing.
local function vendored_body(api)
  return function()
    api.nvim_create_user_command("ClaudeCodeSend", function() end, { range = true, desc = "send" })
    api.nvim_create_user_command("ClaudeCodeAdd", function() end, { nargs = "+", complete = "file", desc = "add" })
    api.nvim_create_user_command("ClaudeCodeSendText", function() end, { nargs = "+", bang = true, desc = "text" })
  end
end

describe("codriver.commands", function()
  describe("capture", function()
    it("records every registration faithfully and creates none of them", function()
      local api = fake_api()

      local captured = commands.capture(vendored_body(api), api)

      assert.are.equal(3, #captured)
      assert.are.equal("ClaudeCodeSend", captured[1].name)
      assert.is_function(captured[1].handler)
      assert.are.equal(
        0,
        #api.created,
        "interception, not cleanup — a created command is one we would have to delete"
      )
    end)

    it("keeps the option flags the commands are useless without", function()
      local api = fake_api()

      local captured = commands.capture(vendored_body(api), api)
      local by_name = {}
      for _, entry in ipairs(captured) do
        by_name[entry.name] = entry
      end

      -- Lose range and `:'<,'>CodriverSend` stops seeing the selection; lose
      -- nargs/complete and `:CodriverAdd` takes no file; lose bang and
      -- `:CodriverSendText!` submits text the user wanted to edit first.
      assert.is_true(by_name.ClaudeCodeSend.opts.range)
      assert.are.equal("+", by_name.ClaudeCodeAdd.opts.nargs)
      assert.are.equal("file", by_name.ClaudeCodeAdd.opts.complete)
      assert.is_true(by_name.ClaudeCodeSendText.opts.bang)
    end)

    it("restores the api and re-raises when the body fails", function()
      local api = fake_api()
      local original_command = api.nvim_create_user_command
      local original_augroup = api.nvim_create_augroup

      local ok, err = pcall(commands.capture, function()
        api.nvim_create_user_command("ClaudeCodeStart", function() end, {})
        error("vendored setup blew up")
      end, api)

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("vendored setup blew up", 1, true), "the failure must not be swallowed")
      -- A leaked shim would eat the user commands of every plugin loaded after
      -- this one, and nothing would point back here.
      assert.are.equal(original_command, api.nvim_create_user_command)
      assert.are.equal(original_augroup, api.nvim_create_augroup)
    end)

    it("restores the api after a successful run too", function()
      local api = fake_api()
      local original_command = api.nvim_create_user_command
      local original_augroup = api.nvim_create_augroup

      commands.capture(vendored_body(api), api)

      assert.are.equal(original_command, api.nvim_create_user_command)
      assert.are.equal(original_augroup, api.nvim_create_augroup)
    end)
  end)

  describe("the augroup bridge", function()
    it("renames the shutdown group so a real claudecode.nvim keeps its own", function()
      local api = fake_api()

      commands.capture(function()
        api.nvim_create_augroup("ClaudeCodeShutdown", { clear = true })
      end, api)

      assert.are.equal(1, #api.augroups)
      assert.are.equal("CodriverShutdown", api.augroups[1].name)
      assert.is_true(api.augroups[1].opts.clear, "the rename must not change what the group does")
    end)

    it("passes the group id back so the caller can attach to it", function()
      local api = fake_api()
      local id

      commands.capture(function()
        id = api.nvim_create_augroup("ClaudeCodeShutdown", { clear = true })
      end, api)

      assert.are.equal(1, id, "a bridge that swallowed the return value would attach the autocmd to nothing")
    end)

    it("leaves every other vendored group alone", function()
      local api = fake_api()

      commands.capture(function()
        -- ClaudeCodeSelection especially: selection.disable() clears it by
        -- literal name, so a renamed group strands its autocmds and makes
        -- stop() throw. This is also the tripwire for a future auto_start
        -- leak, which would run selection.enable inside the shim.
        api.nvim_create_augroup("ClaudeCodeSelection", { clear = true })
        api.nvim_create_augroup("ClaudeCodeMCPDiff", { clear = true })
        api.nvim_create_augroup("ClaudeCodeDiffCleanup", { clear = false })
      end, api)

      assert.are.equal("ClaudeCodeSelection", api.augroups[1].name)
      assert.are.equal("ClaudeCodeMCPDiff", api.augroups[2].name)
      assert.are.equal("ClaudeCodeDiffCleanup", api.augroups[3].name)
    end)

    it("bridges exactly one group", function()
      local bridged = {}
      for from in pairs(commands.augroup_map) do
        table.insert(bridged, from)
      end

      assert.are.same({ "ClaudeCodeShutdown" }, bridged)
    end)
  end)

  describe("the rename map", function()
    it("covers every vendored command and nothing else", function()
      local keys = {}
      for name in pairs(commands.map) do
        table.insert(keys, name)
      end
      table.sort(keys)

      assert.are.same(VENDORED, keys)
    end)

    it("leaves no :ClaudeCode* name in the codriver surface", function()
      for from, to in pairs(commands.map) do
        assert.is_nil(
          to:match("^ClaudeCode"),
          ("%s maps to %s, which is still the other plugin's name"):format(from, to)
        )
        assert.is_truthy(
          to:match("^Codriver"),
          ("%s maps to %s, which is outside codriver's namespace"):format(from, to)
        )
      end
    end)

    it("gives every command its own name", function()
      local seen = {}
      for from, to in pairs(commands.map) do
        assert.is_nil(seen[to], ("%s and %s both map to %s"):format(seen[to], from, to))
        seen[to] = from
      end
    end)
  end)

  describe("register", function()
    it("registers each captured command under its codriver name", function()
      local api = fake_api()
      local captured = commands.capture(vendored_body(api), api)

      local registered = commands.register(captured, api)

      assert.are.same({ "CodriverSend", "CodriverAdd", "CodriverSendText" }, registered)
      assert.are.equal("CodriverSend", api.created[1].name)
      assert.are.equal(captured[1].handler, api.created[1].handler, "the vendored handler is what should run")
      assert.is_true(api.created[1].opts.range, "the flags have to survive the re-export")
    end)

    it("refuses a vendored command it has no name for", function()
      local api = fake_api()
      local captured = { { name = "ClaudeCodeSomethingNew", handler = function() end, opts = {} } }

      local ok, err = pcall(commands.register, captured, api)

      assert.is_false(ok, "silently dropping it would hide the re-sync drift until a user missed the command")
      assert.is_truthy(tostring(err):find("ClaudeCodeSomethingNew", 1, true))
    end)

    it("lets a caller substitute a handler", function()
      local api = fake_api()
      local captured = commands.capture(vendored_body(api), api)
      local replacement = function() end

      commands.register(captured, api, function(name, entry)
        if name == "ClaudeCodeSend" then
          return { name = name, handler = replacement, opts = entry.opts }
        end
        return entry
      end)

      assert.are.equal(replacement, api.created[1].handler)
      assert.is_true(api.created[1].opts.range, "substituting a handler must not drop the flags")
    end)

    it("lets a caller skip a command", function()
      local api = fake_api()
      local captured = commands.capture(vendored_body(api), api)

      local registered = commands.register(captured, api, function(name, entry)
        return name ~= "ClaudeCodeAdd" and entry or nil
      end)

      assert.are.same({ "CodriverSend", "CodriverSendText" }, registered)
      assert.are.equal(2, #api.created)
    end)
  end)
end)
