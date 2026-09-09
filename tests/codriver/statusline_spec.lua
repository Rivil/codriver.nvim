require("tests.busted_setup")

local statusline = require("codriver.statusline")

describe("codriver.statusline", function()
  describe("highlights", function()
    it("gives navigator and driver different attribute tables, not just different colors", function()
      -- c-3: color alone fails colorblind users. Distinct tables (not merely
      -- distinct fg values) is the structural guarantee that a colorscheme
      -- author restyling one cannot accidentally make them equal by hex.
      assert.are_not.same(statusline.highlights.CodriverNavigator, statusline.highlights.CodriverDriver)
    end)

    it("names both highlight groups", function()
      assert.is_not_nil(statusline.highlights.CodriverNavigator)
      assert.is_not_nil(statusline.highlights.CodriverDriver)
    end)
  end)

  describe("component", function()
    it("shares no stem between the navigator and driver label text", function()
      local navigator = statusline.component("navigator")
      local driver = statusline.component("driver")

      assert.are_not.equal(navigator.text, driver.text)
      assert.is_nil(navigator.text:find(driver.text, 1, true))
      assert.is_nil(driver.text:find(navigator.text, 1, true))
    end)

    it("returns a {text, highlight} pair shaped for a lualine component function", function()
      local navigator = statusline.component("navigator")

      assert.is_string(navigator.text)
      assert.is_string(navigator.highlight)
      assert.are.equal("CodriverNavigator", navigator.highlight)
    end)

    it("returns the driver pair for the driver role", function()
      local driver = statusline.component("driver")

      assert.is_string(driver.text)
      assert.are.equal("CodriverDriver", driver.highlight)
    end)
  end)
end)
