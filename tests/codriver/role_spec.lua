require("tests.busted_setup")

local role = require("codriver.role")

describe("codriver.role", function()
  before_each(function()
    role._reset()
    _G.reset_vim_stub()
  end)

  it("starts with Claude as the navigator", function()
    -- The default is load-bearing, not cosmetic: a plugin whose premise is
    -- "you stay the author" must never come up with Claude holding the keyboard.
    assert.are.equal("navigator", role.get())
    assert.is_true(role.is_navigator())
  end)

  it("sets and reports the driver role", function()
    assert.are.equal("driver", role.set("driver"))
    assert.are.equal("driver", role.get())
    assert.is_false(role.is_navigator())
  end)

  it("toggles between the two roles", function()
    assert.are.equal("driver", role.toggle())
    assert.are.equal("navigator", role.toggle())
  end)

  it("rejects an unknown role", function()
    assert.has_error(function()
      role.set("passenger")
    end)
    assert.are.equal("navigator", role.get(), "a rejected set must not change state")
  end)

  it("notifies listeners with the new and previous role", function()
    local seen = {}
    role.on_change(function(new_role, previous)
      table.insert(seen, { new_role = new_role, previous = previous })
    end)

    role.set("driver")

    assert.are.equal(1, #seen)
    assert.are.equal("driver", seen[1].new_role)
    assert.are.equal("navigator", seen[1].previous)
  end)

  it("does not fire listeners when the role is unchanged", function()
    local calls = 0
    role.on_change(function()
      calls = calls + 1
    end)

    role.set("navigator")

    assert.are.equal(0, calls, "setting the current role should be a no-op")
  end)

  it("stops firing a listener after it unsubscribes", function()
    local calls = 0
    local unsubscribe = role.on_change(function()
      calls = calls + 1
    end)

    role.set("driver")
    unsubscribe()
    role.set("navigator")

    assert.are.equal(1, calls)
  end)

  it("isolates a failing listener so the role still changes", function()
    role.on_change(function()
      error("listener blew up")
    end)
    local reached_second = false
    role.on_change(function()
      reached_second = true
    end)

    role.set("driver")

    assert.are.equal("driver", role.get(), "a broken listener must not strand the role")
    assert.is_true(reached_second, "a broken listener must not block the others")
    assert.are.equal(1, #_G.vim._notifications, "the failure should be reported, not swallowed")
    assert.are.equal(vim.log.levels.ERROR, _G.vim._notifications[1].level)
  end)
end)
