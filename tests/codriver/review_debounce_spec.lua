require("tests.busted_setup")

local debounce = require("codriver.review.debounce")

-- `vim.uv.new_timer` is a real-Neovim binding unavailable under bare LuaJIT,
-- so every test injects this fake instead. It mimics just enough of a
-- vim.uv timer's shape (`:start(timeout, repeat, fn)`, `:stop()`) for the
-- debouncer to drive, plus a test-only `fire()` to simulate the quiet period
-- elapsing without a real clock.
---@return table
local function new_fake_timer()
  local pending_fn = nil
  return {
    start = function(_, _, _, fn)
      pending_fn = fn
    end,
    stop = function()
      pending_fn = nil
    end,
    fire = function()
      local fn = pending_fn
      assert(fn, "timer.fire() called with no pending callback")
      pending_fn = nil
      fn()
    end,
  }
end

describe("codriver.review.debounce", function()
  it("never calls the callback synchronously", function()
    local calls = 0
    local timer = new_fake_timer()
    local d = debounce.new(function()
      calls = calls + 1
    end, 500, function()
      return timer
    end)

    d.trigger()

    assert.are.equal(0, calls)
  end)

  it("coalesces 10 trigger() calls into exactly one callback, only after the timer fires", function()
    local calls = 0
    local timer = new_fake_timer()
    local d = debounce.new(function()
      calls = calls + 1
    end, 500, function()
      return timer
    end)

    for _ = 1, 10 do
      d.trigger()
    end
    assert.are.equal(0, calls, "must not fire before the timer does")

    timer.fire()

    assert.are.equal(1, calls)
  end)

  it("produces two separate invocations across a fired window", function()
    local calls = 0
    local timer = new_fake_timer()
    local d = debounce.new(function()
      calls = calls + 1
    end, 500, function()
      return timer
    end)

    d.trigger()
    timer.fire()
    assert.are.equal(1, calls)

    d.trigger()
    timer.fire()
    assert.are.equal(2, calls)
  end)

  it("calls new_timer only once across many triggers, reusing and restarting the same timer", function()
    local created = 0
    local timer = new_fake_timer()
    local d = debounce.new(function() end, 500, function()
      created = created + 1
      return timer
    end)

    d.trigger()
    d.trigger()
    d.trigger()

    assert.are.equal(1, created)
  end)
end)
