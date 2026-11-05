require("tests.busted_setup")

local prompt = require("codriver.review.prompt")

describe("codriver.review.prompt", function()
  it("names the buffer's path and lists only the changed line range", function()
    local text = prompt.build("lua/foo.lua", { { start_line = 12, end_line = 15 } })

    assert.is_truthy(text:find("lua/foo.lua", 1, true), "must name the buffer path")
    assert.is_truthy(text:find("12-15", 1, true), "must list the changed range")
  end)

  it("never mentions the whole file when only a subrange changed", function()
    local text = prompt.build("lua/foo.lua", { { start_line = 40, end_line = 40 } })

    assert.is_falsy(text:find("1%-999"), "must not widen to a whole-file range")
    assert.is_truthy(text:find("40", 1, true))
  end)

  it("contains the literal REVIEW <path>:<line>: <comment> instruction", function()
    local text = prompt.build("lua/foo.lua", { { start_line = 3, end_line = 3 } })

    assert.is_truthy(
      text:find("REVIEW lua/foo.lua:<line>: <comment>", 1, true),
      "must ask for the exact grammar t-6's parser keys on"
    )
  end)

  it("lists every hunk's range when multiple hunks changed", function()
    local text = prompt.build("lua/foo.lua", {
      { start_line = 5, end_line = 5 },
      { start_line = 20, end_line = 22 },
    })

    assert.is_truthy(text:find("5", 1, true))
    assert.is_truthy(text:find("20-22", 1, true))
  end)
end)
