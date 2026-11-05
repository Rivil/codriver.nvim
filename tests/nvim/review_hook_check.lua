-- Register Stop hook, verify end-to-end RPC render — run under real Neovim
-- by `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/review_hook_check.lua
--
-- c-4/c-5: the Stop hook, run as a real subprocess against a live state
-- file, parses a transcript's REVIEW line and RPCs a render into this
-- instance exactly when role=navigator and review_on_save=true — never
-- otherwise, even when the transcript itself looks review-shaped (the
-- double-gate).

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local state = require("codriver.hook.state")

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

local ns = vim.api.nvim_create_namespace("codriver.review")

-- Same reason enforcement_notify_check.lua spawns this way rather than with
-- harness.run()/SystemObj:wait(): an RPC connection the hook subprocess
-- opens back into this process is never accepted while this process is
-- blocked inside :wait().
---@param payload table
---@param env table
---@return { code: integer, stdout: string, stderr: string }
local function run_review_hook_async(payload, env)
  local done, obj = false, nil
  vim.system({ "nvim", "--clean", "-l", harness.repo_root .. "/scripts/codriver-review-hook.lua" }, {
    text = true,
    env = env,
    stdin = vim.json.encode(payload),
  }, function(result)
    obj = result
    done = true
  end)
  vim.wait(10000, function()
    return done
  end, 20)
  harness.expect(done, "the review hook subprocess did not complete within the 10s budget")
  return { code = obj.code, stdout = obj.stdout, stderr = obj.stderr }
end

---A transcript JSONL fixture whose last assistant message's text is `body`.
---@param body string
---@return string path
local function write_transcript(body)
  local path = vim.fn.tempname() .. "-transcript.jsonl"
  vim.fn.writefile({
    vim.json.encode({ type = "user", message = { role = "user", content = "please review" } }),
    vim.json.encode({
      type = "assistant",
      message = { role = "assistant", content = { { type = "text", text = body } } },
    }),
  }, path)
  return path
end

---@param role string
---@param review_on_save boolean
---@return table env
local function live_env(role, review_on_save)
  vim.fn.delete(state.path())
  state.publish({ role = role, review_on_save = review_on_save })
  return { CODRIVER_STATE_FILE = state.path() }
end

local ADDRESS = vim.v.servername
harness.expect(
  type(ADDRESS) == "string" and ADDRESS ~= "",
  "this headless check has no servername for the hook subprocess to RPC into"
)

local bufnr = vim.api.nvim_create_buf(false, true)
local bufname = vim.fn.tempname() .. "-review-hook-target.lua"
vim.api.nvim_buf_set_name(bufnr, bufname)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three" })

local REVIEW_TEXT = ("Looks good overall.\nREVIEW %s:2: consider renaming\n"):format(bufname)

---@param n integer
local function wait_for_extmarks(n)
  vim.wait(1000, function()
    return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}) >= n
  end, 20)
end

-- 1. role=navigator, review_on_save=true, a REVIEW line -> exactly one extmark.
local env1 = vim.tbl_extend("force", live_env("navigator", true), { CODRIVER_NVIM_ADDRESS = ADDRESS })
run_review_hook_async({ transcript_path = write_transcript(REVIEW_TEXT) }, env1)
wait_for_extmarks(1)

local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
harness.expect_eq(#marks, 1, "a REVIEW line while navigator+review_on_save must produce exactly one extmark")

-- 2. review_on_save=false -> zero extmarks (need a fresh notify.arm() cycle:
-- notify.received() is a no-op for a second call without arming, so re-arm
-- to isolate this scenario from the one above).
require("codriver.review.notify").arm()
vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

local env2 = vim.tbl_extend("force", live_env("navigator", false), { CODRIVER_NVIM_ADDRESS = ADDRESS })
run_review_hook_async({ transcript_path = write_transcript(REVIEW_TEXT) }, env2)
vim.wait(200)
harness.expect_eq(#vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}), 0, "review_on_save=false must produce zero extmarks")

-- 3. role=driver -> zero extmarks.
require("codriver.review.notify").arm()
local env3 = vim.tbl_extend("force", live_env("driver", true), { CODRIVER_NVIM_ADDRESS = ADDRESS })
run_review_hook_async({ transcript_path = write_transcript(REVIEW_TEXT) }, env3)
vim.wait(200)
harness.expect_eq(#vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}), 0, "role=driver must produce zero extmarks")

-- 4. A REVIEW-shaped transcript but review_on_save=false: the double-gate
-- must block on the state check alone, before ever parsing the transcript.
require("codriver.review.notify").arm()
local env4 = vim.tbl_extend("force", live_env("navigator", false), { CODRIVER_NVIM_ADDRESS = ADDRESS })
run_review_hook_async({ transcript_path = write_transcript(REVIEW_TEXT) }, env4)
vim.wait(200)
harness.expect_eq(
  #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}),
  0,
  "a REVIEW-shaped transcript with review_on_save=false must not render — the double-gate must block it"
)

vim.api.nvim_buf_delete(bufnr, { force = true })

harness.ok(
  "the Stop hook RPCs a render exactly when role=navigator and review_on_save=true and the transcript contains "
    .. "a REVIEW line, and the double-gate blocks a review-shaped transcript whenever either condition is false"
)
