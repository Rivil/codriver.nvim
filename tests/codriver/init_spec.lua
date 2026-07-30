require("tests.busted_setup")

local codriver = require("codriver")

-- These are the assertions that hold without a real Neovim. Anything touching
-- the vendored protocol layer (setup, get_version) needs the actual vim API and
-- is covered by tests/nvim/vendor_smoke.lua instead.
describe("codriver", function()
  it("exposes a semver-shaped version", function()
    assert.is_number(codriver.version.major)
    assert.is_number(codriver.version.minor)
    assert.is_number(codriver.version.patch)
    assert.are.equal("0.1.0", codriver.version:string())
  end)

  it("exposes setup", function()
    assert.is_function(codriver.setup)
  end)

  it("re-exports role state off the top-level module", function()
    assert.are.equal(require("codriver.role"), codriver.role)
    assert.are.equal("navigator", codriver.role.get())
  end)

  it("does not load the vendored protocol layer just by being required", function()
    -- Requiring codriver must stay cheap and side-effect free: the WebSocket
    -- server and lockfile machinery should only wake up on setup().
    assert.is_nil(package.loaded["codriver.vendor.claudecode"])
  end)
end)
