require("tests.busted_setup")

local dross = require("codriver.dross")

-- read()'s filesystem boundary (vim.fn.getcwd/filereadable/readfile,
-- vim.json.decode) is faked locally per-spec, the same way init_spec.lua
-- fakes vim.fn for codriver.setup() — busted_setup.lua's shared stub stays
-- deliberately minimal (see hook_decision_spec.lua), so a module that
-- legitimately needs vim.fn/vim.json widens it itself, scoped to this file.

local ROOT = "/tmp/dross-spec-root"

---A tiny JSON object decoder good for exactly what these fixtures need: a
---flat object of string keys to string values. Not a general parser — real
---Neovim's vim.json.decode is the real thing; this only has to stand in for
---it under bare LuaJIT.
local function fake_json_decode(text)
  if text:find("not json", 1, true) then
    error("invalid json")
  end
  local result = {}
  for key, value in text:gmatch('"(%a[%w_]*)"%s*:%s*"([^"]*)"') do
    result[key] = value
  end
  return result
end

---Turn a multi-line string into the array-of-lines shape vim.fn.readfile
---returns.
local function lines(text)
  local result = {}
  for line in text:gmatch("[^\n]+") do
    table.insert(result, line)
  end
  return result
end

---@param files table<string, string> path -> file content (unsplit)
local function set_fs(files)
  _G.vim.fn = {
    getcwd = function()
      return ROOT
    end,
    filereadable = function(path)
      return files[path] and 1 or 0
    end,
    readfile = function(path)
      return lines(files[path])
    end,
  }
  _G.vim.json = { decode = fake_json_decode }
end

describe("codriver.dross", function()
  after_each(function()
    _G.vim.fn = nil
    _G.vim.json = nil
  end)

  describe("read", function()
    it("reports unavailable when .dross/state.json is missing", function()
      set_fs({})

      assert.same({ available = false }, dross.read())
    end)

    it("reports unavailable when state.json exists but no phase is current", function()
      set_fs({
        [ROOT .. "/.dross/state.json"] = '{"current_phase_status": "planned"}',
      })

      assert.same({ available = false }, dross.read())
    end)

    it("reports corrupt, not an error, when plan.toml is malformed", function()
      set_fs({
        [ROOT .. "/.dross/state.json"] = '{"current_phase": "phase-x"}',
        [ROOT .. "/.dross/phases/phase-x/plan.toml"] = table.concat({
          "[phase]",
          'id = "phase-x"',
          "",
          "[[task]]",
          'title = "no id on this one"',
          'status = "pending"',
        }, "\n"),
      })

      assert.has_no.errors(function()
        assert.same({ available = false, reason = "corrupt" }, dross.read())
      end)
    end)

    it("extracts phase id and task id/title/status from a valid fixture", function()
      set_fs({
        [ROOT .. "/.dross/state.json"] = '{"current_phase": "phase-x", "current_phase_status": "planned"}',
        [ROOT .. "/.dross/phases/phase-x/plan.toml"] = table.concat({
          "[phase]",
          'id = "phase-x"',
          "",
          "[[task]]",
          'id            = "t-1"',
          "wave          = 1",
          'title         = "First task"',
          'files         = ["a.lua"]',
          'description   = """',
          "Multi-line prose that must not be mistaken for a key = value pair,",
          'including a stray "quoted word" in the middle of a sentence.',
          '"""',
          'covers        = ["c-1"]',
          'status        = "pending"',
          "",
          "[[task]]",
          'id            = "t-2"',
          "wave          = 2",
          'title         = "Second task"',
          'status        = "done"',
        }, "\n"),
      })

      assert.same({
        available = true,
        phase_id = "phase-x",
        tasks = {
          { id = "t-1", title = "First task", status = "pending" },
          { id = "t-2", title = "Second task", status = "done" },
        },
      }, dross.read())
    end)

    it("reports an active phase with no tasks yet when plan.toml doesn't exist", function()
      set_fs({
        [ROOT .. "/.dross/state.json"] = '{"current_phase": "phase-x"}',
      })

      assert.same({ available = true, phase_id = "phase-x", tasks = {} }, dross.read())
    end)
  end)
end)
