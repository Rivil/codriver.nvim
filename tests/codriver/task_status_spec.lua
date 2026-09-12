require("tests.busted_setup")

local task_status = require("codriver.task_status")

-- set()'s vim.system boundary is faked locally per-spec, the same way
-- dross_spec.lua fakes vim.fn for codriver.dross — busted_setup.lua's shared
-- stub stays deliberately minimal, so a module that legitimately needs
-- vim.system widens it itself, scoped to this file.

describe("codriver.task_status", function()
  after_each(function()
    _G.vim.system = nil
  end)

  describe("set", function()
    it("invokes vim.system with the dross task status argv, in order", function()
      local captured_cmd, captured_opts
      _G.vim.system = function(cmd, opts)
        captured_cmd = cmd
        captured_opts = opts
        return {
          wait = function()
            return { code = 0 }
          end,
        }
      end

      task_status.set("phase-x", "t-1", "done")

      assert.same({ "dross", "task", "status", "phase-x", "t-1", "done" }, captured_cmd)
      assert.is_true(captured_opts.text)
    end)

    it("returns {ok = true} on a zero exit code, with no message required", function()
      _G.vim.system = function()
        return {
          wait = function()
            return { code = 0 }
          end,
        }
      end

      local result = task_status.set("phase-x", "t-1", "done")

      assert.is_true(result.ok)
    end)

    it("returns {ok = false, message = <stderr>} on a non-zero exit code", function()
      _G.vim.system = function()
        return {
          wait = function()
            return { code = 1, stderr = "invalid status transition", stdout = "" }
          end,
        }
      end

      local result = task_status.set("phase-x", "t-1", "done")

      assert.is_false(result.ok)
      assert.equals("invalid status transition", result.message)
    end)

    it("falls back to stdout when stderr is empty on a non-zero exit", function()
      _G.vim.system = function()
        return {
          wait = function()
            return { code = 1, stderr = "", stdout = "some stdout diagnostic" }
          end,
        }
      end

      local result = task_status.set("phase-x", "t-1", "done")

      assert.is_false(result.ok)
      assert.equals("some stdout diagnostic", result.message)
    end)

    it("returns {ok = false, message = <error>} instead of raising when vim.system itself raises", function()
      _G.vim.system = function()
        error("ENOENT: dross not found")
      end

      local ok, result = pcall(task_status.set, "phase-x", "t-1", "done")

      assert.is_true(ok)
      assert.is_false(result.ok)
      assert.is_not_nil(result.message)
    end)
  end)
end)
