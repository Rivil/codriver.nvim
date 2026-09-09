require("tests.busted_setup")

local ownership = require("codriver.ownership")

-- claim()/owner()'s filesystem boundary (vim.fn.getcwd/filereadable/readfile/
-- writefile/mkdir, vim.json.encode/decode) is faked locally per-spec, the
-- same way dross_spec.lua fakes it for codriver.dross — see that file's note
-- on why busted_setup.lua's shared stub stays deliberately minimal.

local ROOT = "/tmp/ownership-spec-root"
local PATH = ROOT .. "/.dross/.codriver-ownership.json"

---An in-memory stand-in for the JSON file on disk, keyed by path — good
---enough for a real round-trip through claim()/save()/load() without a real
---filesystem or a real JSON codec.
local function set_fs()
  local files = {}

  _G.vim.fn = {
    getcwd = function()
      return ROOT
    end,
    filereadable = function(path)
      return files[path] and 1 or 0
    end,
    readfile = function(path)
      return { files[path] }
    end,
    writefile = function(lines, path)
      files[path] = lines[1]
    end,
    mkdir = function()
      return 1
    end,
    fnamemodify = function(path)
      return path:match("^(.*)/[^/]+$")
    end,
  }
  _G.vim.json = {
    -- Fixture writes never nest past {phase_id = {task_id = owner}}, so a
    -- tiny two-level encoder/decoder stands in for the real thing.
    encode = function(store)
      local phases = {}
      for phase_id, tasks in pairs(store) do
        local entries = {}
        for task_id, owner in pairs(tasks) do
          table.insert(entries, ('"%s":"%s"'):format(task_id, owner))
        end
        table.insert(phases, ('"%s":{%s}'):format(phase_id, table.concat(entries, ",")))
      end
      return ("{%s}"):format(table.concat(phases, ","))
    end,
    decode = function(text)
      local store = {}
      for phase_id, body in text:gmatch('"([^"]+)":%s*{([^}]*)}') do
        store[phase_id] = {}
        for task_id, owner in body:gmatch('"([^"]+)":"([^"]+)"') do
          store[phase_id][task_id] = owner
        end
      end
      return store
    end,
  }

  return files
end

describe("codriver.ownership", function()
  after_each(function()
    _G.vim.fn = nil
    _G.vim.json = nil
  end)

  describe("claim / owner", function()
    it("returns human for a task never claimed", function()
      set_fs()

      assert.equal("human", ownership.owner("phase-a", "t-1"))
    end)

    it("returns claude for a task claimed in that phase", function()
      set_fs()

      ownership.claim("phase-a", "t-1")

      assert.equal("claude", ownership.owner("phase-a", "t-1"))
    end)

    it("does not let a claim in one phase leak into another phase's same task id", function()
      set_fs()

      ownership.claim("phase-a", "t-1")

      assert.equal("human", ownership.owner("phase-b", "t-1"))
    end)

    it("persists a claim across separate load/save round-trips", function()
      local files = set_fs()

      ownership.claim("phase-a", "t-1")

      assert.is_truthy(files[PATH], "claim() must have written the store to disk")
      assert.equal("claude", ownership.owner("phase-a", "t-1"))
    end)

    it("treats a missing store file as no claims at all", function()
      set_fs()

      assert.equal("human", ownership.owner("phase-a", "anything"))
    end)
  end)

  describe("is_known", function()
    it("is true when the id appears in the task list", function()
      assert.is_true(ownership.is_known("t-1", { { id = "t-1" }, { id = "t-2" } }))
    end)

    it("is false when the id is absent from the task list", function()
      -- :CodriverClaim's WARN case: the claim is still recorded (tested
      -- above), but the id given doesn't match anything dross.read() knows
      -- about — a likely typo, surfaced rather than silently accepted.
      assert.is_false(ownership.is_known("t-9", { { id = "t-1" } }))
    end)

    it("is false for a nil or empty task list", function()
      assert.is_false(ownership.is_known("t-1", nil))
      assert.is_false(ownership.is_known("t-1", {}))
    end)
  end)
end)
