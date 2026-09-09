-- Hook entrypoint: stdin, crash containment, notify — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/hook_entrypoint_check.lua
--
-- Drives the real `scripts/codriver-hook.lua` as a subprocess via
-- harness.run_hook, exactly the way Claude Code invokes the registered
-- PreToolUse command. Deliberately overlaps t-5's hook_decision_spec.lua —
-- that spec proves the pure core's rules; this one proves the entrypoint
-- around it does not lose, mangle, or fail open on the way to stdout.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local notify = require("codriver.hook.notify")
local state = require("codriver.hook.state")

-- Captured before the redirect below: `mise where` (used further down to find
-- a mise-free PATH) stores its trust record under $XDG_STATE_HOME/mise, so a
-- child mise invocation needs this handed back or it resolves an empty trust
-- store out of the sandbox and refuses to run.
local REAL_XDG_STATE_HOME = vim.env.XDG_STATE_HOME

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

local TEST_COMMAND = "mise run test"
local HOOK_CMD = { "nvim", "--clean", "-l", harness.repo_root .. "/scripts/codriver-hook.lua" }

-- Captured refusals delivered over RPC. The hook subprocess connects back to
-- THIS process's own server (real headless Neovim auto-listens, see
-- hook_publish_check.lua) and calls require('codriver.hook.notify').refused
-- inside the SAME Lua state via nvim_exec_lua — patching the cached module
-- here intercepts it without a second process.
local captured = {}
notify.refused = function(payload)
  captured[#captured + 1] = payload
end

local ADDRESS = vim.v.servername
harness.expect(
  type(ADDRESS) == "string" and ADDRESS ~= "",
  "this headless check has no servername for the hook subprocess to notify"
)

---@param tool string
---@param tool_input table|nil
---@param env table|nil
---@return { code: integer, stdout: string, stderr: string }, table|nil
local function run(tool, tool_input, env)
  local merged_env = vim.tbl_extend("force", { CODRIVER_NVIM_ADDRESS = ADDRESS }, env or {})
  local result = harness.run_hook({
    hook_event_name = "PreToolUse",
    tool_name = tool,
    tool_input = tool_input,
  }, merged_env)
  local decoded = nil
  if result.stdout and result.stdout ~= "" then
    local ok, parsed = pcall(vim.json.decode, result.stdout)
    decoded = ok and parsed or nil
  end
  return result, decoded
end

---@param n integer
local function wait_for_notify(n)
  vim.wait(500, function()
    return #captured >= n
  end, 20)
end

---Publish a live record under the sandboxed state home and return the env
---override that points the hook at it.
---@param role string|nil
---@return table
local function live_env(role)
  vim.fn.delete(state.path())
  state.publish({ role = role, test_command = TEST_COMMAND })
  return { CODRIVER_STATE_FILE = state.path() }
end

local NO_SESSION_ENV = { CODRIVER_STATE_FILE = "" }

local function assert_deny_document(decoded, stdout, what)
  harness.expect(type(decoded) == "table", "%s: stdout must parse as JSON, got:\n%s", what, tostring(stdout))
  local keys = {}
  for k in pairs(decoded) do
    keys[#keys + 1] = k
  end
  harness.expect_eq(#keys, 1, what .. ": stdout must carry exactly one top-level key")
  local hso = decoded.hookSpecificOutput
  harness.expect(type(hso) == "table", "%s: stdout must carry hookSpecificOutput", what)
  harness.expect_eq(hso.hookEventName, "PreToolUse", what .. ": hookEventName must be PreToolUse")
  harness.expect_eq(hso.permissionDecision, "deny", what .. ": permissionDecision must be deny")
  harness.expect(
    type(hso.permissionDecisionReason) == "string" and hso.permissionDecisionReason ~= "",
    "%s: permissionDecisionReason must be a non-empty string",
    what
  )
  harness.expect_not_contains(stdout, "\n", what .. ": stdout must be a single line, nothing else")
end

-- 1. An allow is silent: empty stdout, exit 0. An emitted explicit-allow
-- document would auto-approve every tool the user never consented to.
captured = {}
local allow_result, allow_decoded = run("Read", { file_path = "x" }, live_env("navigator"))
harness.expect_eq(allow_result.code, 0, "an allowed call must exit 0")
harness.expect_eq(allow_result.stdout, "", "an allowed call must print nothing")
harness.expect_eq(allow_decoded, nil, "an allowed call's stdout must not parse as anything")
wait_for_notify(1)
harness.expect_eq(#captured, 0, "an allowed call must not notify — that chatters at the editor during normal work")

-- 2. The deny payload shape, read back rather than assumed.
captured = {}
local deny_result, deny_decoded = run("Edit", { file_path = "foo.lua" }, live_env("navigator"))
harness.expect_eq(deny_result.code, 0, "a denied call must exit 0 — Claude Code reads the deny from the document")
assert_deny_document(deny_decoded, deny_result.stdout, "navigator deny")
local navigator_reason = deny_decoded.hookSpecificOutput.permissionDecisionReason:lower()
harness.expect(navigator_reason:find("navigator", 1, true) ~= nil, "the navigator deny reason must name the role")

-- No live session at all: the hook lives in the repo permanently, so a plain
-- `claude` run with no Neovim behind it must not be crippled by enforcement
-- with nothing to enforce — even a normally-denied tool is allowed.
captured = {}
local plain_result = run("Edit", { file_path = "x" }, NO_SESSION_ENV)
harness.expect_eq(plain_result.code, 0, "no live session: must exit 0")
harness.expect_eq(plain_result.stdout, "", "no live session must allow silently, same as any other allow")

-- 3 + 4. Crash containment: an internal failure inside a live session must be
-- the same observable as an intentional deny — exit 0, deny document — never
-- a bare non-zero exit, which Claude Code reads as a non-blocking hook error
-- and lets the tool call straight through.
--
-- Every case below runs the real registered command with a bounded timeout —
-- a hang here would otherwise wedge the whole check rather than fail it — and
-- shares one assertion: exit 0, and stdout parses as the deny document.
local EDIT_PAYLOAD =
  vim.json.encode({ hook_event_name = "PreToolUse", tool_name = "Edit", tool_input = { file_path = "x" } })

---@param what string
---@param opts table extra vim.system opts (env is merged over CODRIVER_NVIM_ADDRESS)
local function assert_fails_closed(what, opts)
  opts = vim.tbl_extend("force", { timeout = 10000 }, opts)
  opts.env = vim.tbl_extend("force", { CODRIVER_NVIM_ADDRESS = ADDRESS }, opts.env or {})
  local result = harness.run(HOOK_CMD, opts)
  harness.expect_eq(result.code, 0, what .. ": must exit 0, not a bare non-zero exit")
  local ok, decoded = pcall(vim.json.decode, result.stdout or "")
  assert_deny_document(ok and decoded or nil, result.stdout, what)
  return result
end

-- 4a. Unparsable stdin.
assert_fails_closed("unparsable stdin", { env = live_env("navigator"), stdin = "{ not actually json" })

-- 4b. Valid JSON of the wrong shape (an array instead of the expected object).
assert_fails_closed("wrong-shape JSON", { env = live_env("navigator"), stdin = "[1, 2, 3]" })

-- 4c. The state file replaced by a directory: read() must not raise, and the
-- resulting role-unreadable session must still deny (c-7), not crash.
do
  local path = live_env("navigator").CODRIVER_STATE_FILE
  vim.fn.delete(path, "rf")
  vim.fn.mkdir(path, "p")
  assert_fails_closed("state file as a directory", { env = { CODRIVER_STATE_FILE = path }, stdin = EDIT_PAYLOAD })
  vim.fn.delete(path, "rf")
end

-- 4d. A decision-core raise: Bash with no `command` field walks straight into
-- codriver.hook.bash indexing a nil string. A live session must still deny
-- rather than let the crash read as a non-blocking hook error.
assert_fails_closed("decision-core raise", {
  env = live_env("navigator"),
  stdin = vim.json.encode({ hook_event_name = "PreToolUse", tool_name = "Bash", tool_input = {} }),
})

-- 5. package.path is derived from the script's own location, not the cwd —
-- proven by running from `/`, where nothing on a normal cwd-relative path
-- would resolve.
assert_fails_closed("cwd=/", { env = live_env("navigator"), stdin = EDIT_PAYLOAD, cwd = "/" })

-- 6. No toolchain dependency: PATH stripped to only the directory holding the
-- real `nvim` binary must still work — no mise, no luarocks. Resolved via
-- `mise where neovim` (the same technique mise.toml's own [tasks.setup] uses
-- for luajit) rather than exepath("nvim"), which would just as happily find
-- mise's own shim and prove nothing about a mise-free PATH.
do
  local mise_where = harness.run({ "mise", "where", "neovim" }, {
    env = {
      HOME = harness.real_home,
      -- Falls back to the XDG default (unset is the common case) rather than
      -- passing an empty override, which vim.system treats as absent and
      -- leaves the redirected $XDG_STATE_HOME from above in place.
      XDG_STATE_HOME = REAL_XDG_STATE_HOME or (harness.real_home .. "/.local/state"),
    },
  })
  harness.expect_eq(mise_where.code, 0, "`mise where neovim` failed: " .. (mise_where.stderr or ""))
  local nvim_dir = vim.trim(mise_where.stdout) .. "/bin"
  local env = vim.tbl_extend("force", live_env("navigator"), { PATH = nvim_dir })
  assert_fails_closed("stripped PATH", { env = env, stdin = EDIT_PAYLOAD })
end

-- 7. A dead CODRIVER_NVIM_ADDRESS must not hang or change the decision —
-- notification failure must never affect the decision the hook already made.
do
  local env = vim.tbl_extend("force", live_env("navigator"), {
    CODRIVER_NVIM_ADDRESS = harness.sandbox_root .. "/no-such-socket",
  })
  assert_fails_closed("dead notify address", { env = env, stdin = EDIT_PAYLOAD })
end

-- 8. The hook is a decision, not an actor: the Edit payload it was asked
-- about must be byte-identical before and after, whether allowed or denied.
do
  local target = harness.sandbox_root .. "/workspace/file.lua"
  local original = "-- original contents\nreturn 1"
  harness.write(target, original)

  run("Edit", { file_path = target }, live_env("navigator"))
  harness.expect_eq(
    table.concat(vim.fn.readfile(target), "\n"),
    original,
    "a denied Edit must leave its target file byte-identical"
  )

  run("Edit", { file_path = target }, live_env("driver"))
  harness.expect_eq(
    table.concat(vim.fn.readfile(target), "\n"),
    original,
    "an allowed Edit must still leave its target file untouched — the hook decides, it never writes"
  )
end

-- 9. --clean means no user configuration, even though this hook's own script
-- is loaded with `-l`. A planted $XDG_CONFIG_HOME/nvim/init.lua must never run.
do
  local config_home = harness.sandbox_root .. "/fake-xdg-config"
  local marker = harness.sandbox_root .. "/user-init-ran"
  harness.write(config_home .. "/nvim/init.lua", ([[vim.fn.writefile({"ran"}, %q)]]):format(marker))
  local env = live_env("navigator")
  run("Edit", { file_path = "x" }, vim.tbl_extend("force", env, { XDG_CONFIG_HOME = config_home }))
  harness.expect_eq(
    vim.fn.filereadable(marker),
    0,
    "a planted user init.lua ran during the hook — --clean must keep user configuration out of the enforcement path"
  )
end

harness.ok(
  "the hook prints nothing on allow, an exact deny document on refusal, fails closed rather than crashing on "
    .. "garbled stdin/a raising decision core/a state file replaced by a directory, resolves its own modules "
    .. "regardless of cwd or PATH, survives a dead notify address without hanging, never touches the file it was "
    .. "asked about, and never loads user configuration"
)
