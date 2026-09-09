-- Self-check for the headless runner and the harness itself.
--
-- Everything else under tests/nvim/ trusts two things: that a failing assertion
-- actually fails the build, and that `mise run test-nvim` finds and isolates the
-- checks. Neither is visible from inside a passing check — a harness that
-- printed its failures and returned would make every check here vacuous. So
-- this one drives both from the outside, with deliberately failing children.
--
-- It re-enters `mise run test-nvim`. The temporary checks it plants are named to
-- sort first, so the runner's stop-at-first-failure keeps the nested run to
-- three short nvim processes, and $CODRIVER_SELFCHECK stops the nested copy of
-- this file from recursing if it is ever reached.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

if vim.env.CODRIVER_SELFCHECK == "1" then
  harness.ok("nested runner invocation — assertions skipped")
  return
end

local repo = harness.repo_root
local harness_path = here .. "/harness.lua"
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

-- Files planted inside tests/nvim. The harness exits the process on a failed
-- assertion, so nothing may be asserted while these exist — gather evidence,
-- clean up, then assert. The autocmd is a backstop for a crash in between.
local planted = {}

local function plant(name, contents)
  local path = ("%s/%s"):format(here, name)
  harness.write(path, contents)
  table.insert(planted, path)
  return path
end

local function unplant()
  for _, path in ipairs(planted) do
    pcall(vim.fn.delete, path)
  end
  planted = {}
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = unplant })

---Run `mise run test-nvim` from the repo root.
---
---$HOME has to be handed back or mise resolves its own config out of the empty
---sandbox; $CLAUDE_CONFIG_DIR is cleared so each nested check sandboxes itself
---rather than sharing this process's lock directory.
---@param env table|nil extra environment
---@return vim.SystemCompleted
local function run_runner(env)
  local merged = vim.tbl_extend("force", {
    HOME = harness.real_home,
    CLAUDE_CONFIG_DIR = "",
    CODRIVER_SELFCHECK = "1",
  }, env or {})
  local ok, res = pcall(harness.run, { "mise", "run", "test-nvim" }, { cwd = repo, env = merged })
  if not ok then
    unplant()
    harness.fail("could not run `mise run test-nvim`: %s", res)
  end
  return res
end

-- 1. A failed harness assertion must kill the process ------------------------

local function run_child(name, body)
  local path = ("%s/%s.lua"):format(tmp, name)
  harness.write(path, ("local harness = dofile(%q).setup()\n%s\n"):format(harness_path, body))
  return harness.run({ vim.v.progpath, "--clean", "--headless", "-l", path })
end

local failing = run_child("failing_expect", 'harness.expect(false, "deliberate failure: %s", "selfcheck")')
harness.expect(failing.code ~= 0, "a child whose harness assertion fails must exit non-zero, got %d", failing.code)
harness.expect_contains(failing.stderr, "deliberate failure: selfcheck", "the failure message must reach stderr")

local passing = run_child("passing_expect", 'harness.expect(true, "unreachable")\nharness.ok("fine")')
harness.expect_eq(passing.code, 0, "a child whose harness assertions hold must exit 0")

-- 2. The harness refuses a lock directory it does not own --------------------

local escaped = run_child("escaped_lock_dir", 'harness.ok("sandbox accepted %s", vim.env.CLAUDE_CONFIG_DIR)')
harness.expect_eq(escaped.code, 0, "sanity: the child template itself must pass")

local outside = ("%s/.claude"):format(harness.real_home)
local refused = harness.run({
  vim.v.progpath,
  "--clean",
  "--headless",
  "-l",
  ("%s/escaped_lock_dir.lua"):format(tmp),
}, { env = { CLAUDE_CONFIG_DIR = outside } })
harness.expect(refused.code ~= 0, "the harness must refuse a CLAUDE_CONFIG_DIR outside the temp root")
harness.expect_contains(refused.stderr, "refusing to run", "the refusal must say why")

-- 3. Discovery, per-check isolation, and stop-at-first-failure ---------------

local marker = tmp .. "/pids.txt"
local recorder = ([[
local harness = dofile(%q).setup()
local path = assert(vim.env.CODRIVER_SELFCHECK_MARKER, "marker path was not passed down")
local fh = assert(io.open(path, "a"))
fh:write(tostring(vim.fn.getpid()) .. "\n")
fh:close()
harness.ok("recorded pid")
]]):format(harness_path)

-- Sorted first, so the runner reaches the failure without spending a process on
-- every real check. Nothing registers them anywhere: being named *_check.lua in
-- this directory is the whole of their registration, which is what proves
-- discovery is glob-derived rather than a list in mise.toml.
plant("aaa_selfcheck_tmp1_check.lua", recorder)
plant("aab_selfcheck_tmp2_check.lua", recorder)
plant(
  "aac_selfcheck_tmp3_check.lua",
  ('local harness = dofile(%q).setup()\nharness.expect(false, "deliberate failure from the harness selfcheck")\n'):format(
    harness_path
  )
)

local nested = run_runner({ CODRIVER_SELFCHECK_MARKER = marker })
local nested_out = (nested.stdout or "") .. (nested.stderr or "")
local pids = vim.fn.filereadable(marker) == 1 and vim.fn.readfile(marker) or {}
unplant()

harness.expect(nested.code ~= 0, "the runner must exit non-zero when a check fails, got %d", nested.code)
harness.expect_contains(nested_out, "aaa_selfcheck_tmp1_check.lua", "the runner must discover checks by glob")
harness.expect_contains(nested_out, "aac_selfcheck_tmp3_check.lua", "the runner must name the check that failed")
harness.expect_not_contains(nested_out, "vendor_smoke_check.lua", "the runner must stop at the first failing check")
harness.expect_eq(#pids, 2, "both planted passing checks must have run")
harness.expect(pids[1] ~= pids[2], "each check needs its own nvim process (both reported pid %s)", tostring(pids[1]))

-- 4. The naming convention is enforced before anything runs -----------------

plant("aaa_selfcheck_tmp_spec.lua", "-- deliberately misnamed; the runner must refuse to start\n")
local misnamed = run_runner()
local misnamed_out = (misnamed.stdout or "") .. (misnamed.stderr or "")
unplant()

harness.expect(misnamed.code ~= 0, "the runner must refuse a tests/nvim file that is not a *_check.lua")
harness.expect_contains(misnamed_out, "aaa_selfcheck_tmp_spec.lua", "the refusal must name the offending file")
harness.expect_not_contains(misnamed_out, "all checks passed", "the runner must not run anything after refusing")

-- 5. The two suites stay on their own side of the naming line ---------------

local mise = table.concat(vim.fn.readfile(repo .. "/mise.toml"), "\n")
harness.expect_contains(
  mise,
  [[find tests -type f \( -name "*_test.lua" -o -name "*_spec.lua" \)]],
  "[tasks.test] must parenthesise the -o group, or -type f binds to the first -name only"
)

harness.expect_eq(
  vim.fn.filereadable(here .. "/vendor_smoke_check.lua"),
  1,
  "the vendored-require-resolution check must be discoverable under its *_check.lua name"
)
harness.expect_eq(
  vim.fn.filereadable(here .. "/vendor_smoke.lua"),
  0,
  "the pre-rename vendor_smoke.lua path must be gone, not left behind as a second copy"
)

harness.ok("runner discovery, process isolation, fail-fast and fatal assertions all hold")
