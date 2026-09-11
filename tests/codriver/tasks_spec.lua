require("tests.busted_setup")

local tasks = require("codriver.tasks")

-- render() requires codriver.dross/codriver.ownership at call time, not at
-- module load — see tasks.lua's note — so a fake in package.loaded here is
-- picked up on the very next render() call. open()'s real buffer/float and
-- close-on-any-key are covered headlessly instead (tests/nvim/tasks_check.lua):
-- busted has no real vim.api to open a window against.

local DROSS = "codriver.dross"
local OWNERSHIP = "codriver.ownership"

---@param read_fn function
local function fake_dross(read_fn)
  return { read = read_fn }
end

---@param owner_fn function|nil
local function fake_ownership(owner_fn)
  return {
    HUMAN = "human",
    CLAUDE = "claude",
    owner = owner_fn or function()
      return "human"
    end,
  }
end

describe("codriver.tasks", function()
  local saved

  before_each(function()
    saved = { [DROSS] = package.loaded[DROSS], [OWNERSHIP] = package.loaded[OWNERSHIP] }
  end)

  after_each(function()
    package.loaded[DROSS] = saved[DROSS]
    package.loaded[OWNERSHIP] = saved[OWNERSHIP]
  end)

  describe("render", function()
    it("re-reads dross.read() on every call", function()
      -- The whole point of c-4: two calls straddling an on-disk edit (here,
      -- straddling a change in what the fake returns) must not answer from a
      -- cache taken at the first call.
      local calls = 0
      package.loaded[DROSS] = fake_dross(function()
        calls = calls + 1
        local status_word = calls == 1 and "pending" or "done"
        return {
          available = true,
          phase_id = "phase-x",
          tasks = { { id = "t-1", title = "First", status = status_word } },
        }
      end)
      package.loaded[OWNERSHIP] = fake_ownership()

      local first = tasks.render()
      local second = tasks.render()

      assert.equal(2, calls)
      assert.are_not.same(first, second)
      assert.is_truthy(first.lines[1]:find("pending", 1, true))
      assert.is_truthy(second.lines[1]:find("done", 1, true))
    end)

    it("lists id, title, status and owner for each task", function()
      package.loaded[DROSS] = fake_dross(function()
        return {
          available = true,
          phase_id = "phase-x",
          tasks = {
            { id = "t-1", title = "First task", status = "pending" },
            { id = "t-2", title = "Second task", status = "done" },
          },
        }
      end)
      package.loaded[OWNERSHIP] = fake_ownership(function(phase_id, task_id)
        assert.equal("phase-x", phase_id)
        return task_id == "t-1" and "claude" or "human"
      end)

      local rendered = tasks.render()

      assert.is_true(rendered.available)
      assert.equal("phase-x", rendered.phase_id)
      assert.equal(2, #rendered.lines)
      assert.is_truthy(rendered.lines[1]:find("t-1", 1, true))
      assert.is_truthy(rendered.lines[1]:find("First task", 1, true))
      assert.is_truthy(rendered.lines[1]:find("pending", 1, true))
      assert.is_truthy(rendered.lines[1]:find("claude", 1, true))
      assert.is_truthy(rendered.lines[2]:find("human", 1, true))
    end)

    it("passes an unavailable, corrupt result through rather than erroring", function()
      package.loaded[DROSS] = fake_dross(function()
        return { available = false, reason = "corrupt" }
      end)

      local rendered = tasks.render()

      assert.is_false(rendered.available)
      assert.equal("corrupt", rendered.reason)
    end)

    it("passes an unavailable, no-active-phase result through with no reason", function()
      package.loaded[DROSS] = fake_dross(function()
        return { available = false }
      end)

      local rendered = tasks.render()

      assert.is_false(rendered.available)
      assert.is_nil(rendered.reason)
    end)

    it('computes an exact "yours: N  claude: M" header from the phase\'s current tasks', function()
      package.loaded[DROSS] = fake_dross(function()
        return {
          available = true,
          phase_id = "phase-x",
          tasks = {
            { id = "t-1", title = "First", status = "pending" },
            { id = "t-2", title = "Second", status = "pending" },
            { id = "t-3", title = "Third", status = "done" },
          },
        }
      end)
      package.loaded[OWNERSHIP] = fake_ownership(function(_, task_id)
        return task_id == "t-1" and "claude" or "human"
      end)

      local rendered = tasks.render()

      assert.equal("yours: 2  claude: 1", rendered.header)
    end)

    it("keeps rendered.lines task-only — the header lives in a separate field, not lines[1]", function()
      package.loaded[DROSS] = fake_dross(function()
        return {
          available = true,
          phase_id = "phase-x",
          tasks = { { id = "t-1", title = "First", status = "pending" } },
        }
      end)
      package.loaded[OWNERSHIP] = fake_ownership()

      local rendered = tasks.render()

      assert.equal(1, #rendered.lines)
      assert.is_truthy(rendered.lines[1]:find("t-1", 1, true))
      assert.equal("yours: 1  claude: 0", rendered.header)
    end)
  end)
end)
