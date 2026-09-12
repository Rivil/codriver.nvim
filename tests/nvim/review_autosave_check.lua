-- Wire BufWritePost review trigger into setup() — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/review_autosave_check.lua
--
-- c-1/c-2/c-3/c-5/c-6: a save fires exactly one debounced review while
-- navigator with review_on_save on and something changed; driver mode,
-- review_on_save=false, an unchanged buffer, and a burst of rapid saves all
-- produce zero (or exactly one, for the burst) call; a failed send leaves
-- the snapshot un-advanced so the dropped change survives to the next save.
--
-- role and send_to_terminal are injected fakes — this exercises the trigger
-- wiring itself, not the real vendored terminal or the real role singleton.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local autosave = require("codriver.review.autosave")

local calls = {}
local send_result = true
local function fake_send(text, send_opts)
  table.insert(calls, { text = text, opts = send_opts })
  return send_result
end

local role_state = "navigator"
local fake_role = {
  is_navigator = function()
    return role_state == "navigator"
  end,
}

-- The same table autosave.install() closes over; mutating it after install
-- changes what the next fire() sees, so scenarios below can flip
-- review_on_save without reinstalling the autocmd.
local opts = {
  review_on_save = true,
  role = fake_role,
  send_to_terminal = fake_send,
  delay_ms = 20,
}

autosave.install(opts)

local file = vim.fn.tempname() .. "-review-autosave.lua"
vim.cmd("edit " .. vim.fn.fnameescape(file))
local bufnr = vim.api.nvim_get_current_buf()

---@param expected integer
---@param what string
local function wait_for_calls(expected, what)
  local ok = vim.wait(500, function()
    return #calls == expected
  end, 10)
  harness.expect(ok, ("%s (expected %d call(s), got %d)"):format(what, expected, #calls))
end

-- --------------------------------------------------- 1. first-ever write ---
--
-- No snapshot exists yet: this save only establishes the baseline.

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three" })
vim.cmd("write")
vim.wait(80)
harness.expect_eq(#calls, 0, "the first-ever save for a buffer must only establish the baseline, not fire")

-- ---------------------------------- 2. navigator + changed -> exactly one ---

vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "TWO CHANGED" })
vim.cmd("write")
wait_for_calls(1, "a changed buffer while navigator with review_on_save=true must fire exactly one review")

harness.expect_eq(calls[1].opts.submit, true, "the call must pass {submit = true}")
harness.expect_match(calls[1].text, "REVIEW ", "the prompt must ask for the REVIEW grammar")

-- --------------------------------------------------------- 3. role=driver ---

role_state = "driver"
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "ONE CHANGED WHILE DRIVER" })
vim.cmd("write")
vim.wait(80)
harness.expect_eq(#calls, 1, "a changed buffer while driver must fire zero reviews")
role_state = "navigator"

-- --------------------------------------------------- 4. review_on_save=false ---

opts.review_on_save = false
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "ONE CHANGED AGAIN" })
vim.cmd("write")
vim.wait(80)
harness.expect_eq(#calls, 1, "review_on_save=false must fire zero reviews regardless of role")
opts.review_on_save = true

-- Neither of the two gated-out saves above advanced the snapshot, so this
-- save (navigator, enabled again) now sees everything that piled up since
-- step 2 and fires for real, bringing the snapshot back in sync.
vim.cmd("write")
wait_for_calls(2, "re-enabling review_on_save with role=navigator must pick back up and fire")

-- --------------------------------------------------- 5. no diff -> zero ---

vim.cmd("write")
vim.wait(80)
harness.expect_eq(#calls, 2, "a write with no diff since the last snapshot must fire zero reviews")

-- ------------------------------------------- 6. 10 rapid writes -> one call ---

vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "THREE CHANGED" })
for _ = 1, 10 do
  vim.cmd("write")
end
wait_for_calls(3, "10 rapid :write calls inside the debounce window must coalesce into exactly one call")

-- ------------------------------------- 7. failed send does not advance ---

send_result = false
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "DROPPED CHANGE" })
vim.cmd("write")
wait_for_calls(4, "a failed send must still be attempted")

send_result = true
-- No further edit: if the snapshot had wrongly advanced despite the failed
-- send, this write would see no diff and fire zero more times.
vim.cmd("write")
wait_for_calls(5, "the next save must still include the change a failed send dropped")

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(file)

harness.ok(
  "BufWritePost fires a debounced review exactly when navigator + review_on_save + something changed, "
    .. "coalesces a save burst into one call, and never advances the snapshot on a failed send"
)
