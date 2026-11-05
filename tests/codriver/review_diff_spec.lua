require("tests.busted_setup")

local snapshot = require("codriver.review.snapshot")
local diff = require("codriver.review.diff")

-- `vim.diff` is a real-Neovim C binding that does not exist under bare
-- LuaJIT, so every test here injects `diff_fn` explicitly rather than
-- relying on the module's `vim.diff` default. That default is exercised in
-- tests/nvim/ instead — see the sibling t-8/t-10 nvim checks.
---@param entries table[] each {start_a, count_a, start_b, count_b}
---@return function
local function fake_diff(entries)
  return function()
    return entries
  end
end

describe("codriver.review.diff", function()
  before_each(function()
    _G.reset_vim_stub()
  end)

  it("returns nil when bufnr has never been snapshotted", function()
    assert.is_nil(diff.diff(4321, { "a" }, fake_diff({})))
  end)

  it("returns {} when lines are identical to the last advance() call, without calling diff_fn", function()
    snapshot.advance(1, { "a", "b", "c" })

    local called = false
    local result = diff.diff(1, { "a", "b", "c" }, function()
      called = true
      return {}
    end)

    assert.are.same({}, result)
    assert.is_false(called, "an identical buffer must short-circuit before touching diff_fn")
  end)

  it("scopes a hunk to the changed line, not the whole buffer", function()
    local lines = {}
    for i = 1, 100 do
      lines[i] = ("line %d"):format(i)
    end
    snapshot.advance(2, lines)

    local changed = {}
    for i, line in ipairs(lines) do
      changed[i] = line
    end
    changed[50] = "changed line 50"

    -- A real vim.diff on this input would itself report a single-line hunk;
    -- the fake stands in for that and lets this test assert on how *this
    -- module* shapes the raw indices, not on vim.diff's own correctness.
    local hunks = diff.diff(2, changed, fake_diff({ { 50, 1, 50, 1 } }))

    assert.are.equal(1, #hunks)
    assert.are.same({ start_line = 50, end_line = 50 }, hunks[1])
  end)

  it("expands a multi-line hunk to start_line..end_line", function()
    snapshot.advance(3, { "a", "b", "c" })

    local hunks = diff.diff(3, { "a", "x", "y", "c" }, fake_diff({ { 2, 1, 2, 2 } }))

    assert.are.same({ { start_line = 2, end_line = 3 } }, hunks)
  end)

  it("anchors a pure deletion at its removal point in the new buffer", function()
    snapshot.advance(6, { "a", "b", "c" })

    local hunks = diff.diff(6, { "a", "c" }, fake_diff({ { 2, 1, 1, 0 } }))

    assert.are.same({ { start_line = 1, end_line = 1 } }, hunks)
  end)
end)
