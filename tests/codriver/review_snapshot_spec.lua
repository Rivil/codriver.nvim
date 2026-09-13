require("tests.busted_setup")

local snapshot = require("codriver.review.snapshot")

describe("codriver.review.snapshot", function()
  it("returns nil for a bufnr that has never been advanced", function()
    assert.is_nil(snapshot.get(999))
  end)

  it("advance() then get() returns the recorded lines", function()
    local lines = { "local x = 1", "return x" }

    snapshot.advance(1, lines)

    assert.are.same(lines, snapshot.get(1))
  end)

  it("advance() then clear() makes get() return nil", function()
    snapshot.advance(5, { "a" })

    snapshot.clear(5)

    assert.is_nil(snapshot.get(5))
  end)

  it("keeps snapshots for two different bufnrs independent", function()
    snapshot.advance(10, { "buf ten" })
    snapshot.advance(20, { "buf twenty" })

    assert.are.same({ "buf ten" }, snapshot.get(10))
    assert.are.same({ "buf twenty" }, snapshot.get(20))

    snapshot.clear(10)

    assert.is_nil(snapshot.get(10))
    assert.are.same({ "buf twenty" }, snapshot.get(20))
  end)

  it("advance() replaces a prior snapshot for the same bufnr", function()
    snapshot.advance(7, { "old" })
    snapshot.advance(7, { "new" })

    assert.are.same({ "new" }, snapshot.get(7))
  end)
end)
