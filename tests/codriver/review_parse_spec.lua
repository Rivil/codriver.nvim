require("tests.busted_setup")

local parse = require("codriver.review.parse")

describe("codriver.review.parse", function()
  it("parses a REVIEW line into one {file, line, text} entry", function()
    local comments = parse.parse("REVIEW lua/foo.lua:12: consider renaming")

    assert.are.equal(1, #comments)
    assert.are.same({ file = "lua/foo.lua", line = 12, text = "consider renaming" }, comments[1])
  end)

  it("ignores a non-REVIEW line", function()
    local comments = parse.parse("Looks good overall, nice work.")

    assert.are.same({}, comments)
  end)

  it("yields two entries for two REVIEW lines for the same file at different lines", function()
    local comments = parse.parse(table.concat({
      "REVIEW lua/foo.lua:3: nit here",
      "REVIEW lua/foo.lua:9: and here",
    }, "\n"))

    assert.are.equal(2, #comments)
    assert.are.same({ file = "lua/foo.lua", line = 3, text = "nit here" }, comments[1])
    assert.are.same({ file = "lua/foo.lua", line = 9, text = "and here" }, comments[2])
  end)

  it("skips a non-numeric line field instead of raising", function()
    assert.has_no.errors(function()
      local comments = parse.parse("REVIEW lua/foo.lua:abc: broken")
      assert.are.same({}, comments)
    end)
  end)

  it("ignores prose around REVIEW lines in the same reply", function()
    local comments = parse.parse(table.concat({
      "Here is my review:",
      "REVIEW lua/foo.lua:5: extract this",
      "Otherwise looks fine.",
    }, "\n"))

    assert.are.equal(1, #comments)
    assert.are.equal(5, comments[1].line)
  end)
end)
