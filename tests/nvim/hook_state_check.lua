-- Session state file and liveness probe — run under real Neovim by
-- `mise run test-nvim`, or alone:
--
--   nvim --clean --headless -l tests/nvim/hook_state_check.lua
--
-- This lives in the headless-Neovim lane rather than under busted because every
-- claim it makes is about the real world: `stdpath("state")` resolving against a
-- live $XDG_STATE_HOME, `vim.uv.kill` answering for a real process, and an
-- actual rename landing on an actual filesystem. The minimal busted stub can
-- fake all three, and a faked liveness probe proves nothing about the question
-- `no_session_behaviour` makes security-relevant.
--
-- Three shapes are pinned here that the plan named but did not fully specify.
-- They are asserted rather than assumed, so disagreeing means changing this file
-- deliberately rather than discovering the difference in t-10:
--
--   * `publish(record)` owns `schema` and `pid`; the caller supplies `role` and
--     `test_command`. A caller that had to know the schema version would defeat
--     the point of versioning it.
--   * `read(path)` returns `nil, <reason>` with the missing and corrupt reasons
--     distinguishable, because the caller allows on the first and denies on the
--     second.
--   * `probe(env)` reads `env.CODRIVER_STATE_FILE` (the name t-6 injects) and
--     returns a table, never a boolean: `{live = false}` for no session,
--     `{live = true, role = nil}` for live-but-role-unreadable, and
--     `{live = true, role = ...}` for live-with-role. Liveness comes from the
--     pid in the *filename*, so a session whose record has been deleted is still
--     correctly seen as live rather than collapsing into no-session-at-all.
--
-- Harness assertions are fatal, so the patched write primitives in the
-- atomicity section are restored before anything is asserted.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

-- Required BEFORE $XDG_STATE_HOME moves, so a module that resolves its path at
-- load time is caught rather than accommodated. `setup()` has already repointed
-- $HOME, so such a module lands under <sandbox>/home/.local/state rather than
-- the developer's real one — still a different subtree from the redirect below,
-- which is what the first assertion detects.
local state = require("codriver.hook.state")

local STATE_HOME = harness.sandbox_root .. "/state"
vim.fn.mkdir(STATE_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = STATE_HOME

---Absolute, symlink-resolved, trailing-slash-free form of a path.
---@param path string
---@return string
local function resolved(path)
  return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
end

---True when `path` is inside `dir`.
---@param path string
---@param dir string
---@return boolean
local function is_inside(path, dir)
  local root = resolved(dir)
  return resolved(path):sub(1, #root + 1) == root .. "/"
end

---A pid with no process behind it, proven rather than assumed.
---@return integer
local function dead_pid()
  for candidate = 999999, 900000, -1 do
    if not vim.uv.kill(candidate, 0) then
      return candidate
    end
  end
  harness.fail("could not find a dead pid to build a stale record with")
  return 0
end

-- 1. The path is resolved per call, not frozen at module load.
local path = state.path()
harness.expect(
  is_inside(path, STATE_HOME),
  "path() resolved to %s, outside the redirected XDG_STATE_HOME %s — the state path is frozen at module load "
    .. "rather than resolved per call, the same trap the harness guards for the vendored lock_dir",
  path,
  STATE_HOME
)

-- 2. And it never lands inside the working tree.
harness.expect(
  not is_inside(path, vim.fn.getcwd()),
  "path() resolved to %s, inside the working tree %s — a state file in the tree is a role switch reachable "
    .. "from a tool call",
  path,
  vim.fn.getcwd()
)

-- Matched on the filename rather than as a substring of the whole path: the
-- sandbox root is a tempname full of random digits, and a substring test can
-- pass on a coincidence.
harness.expect_eq(
  vim.fn.fnamemodify(path, ":t"),
  vim.uv.os_getpid() .. ".json",
  "path() must be named for the owning pid — probe() recovers it from the filename once the contents are gone"
)

-- Resolved per call, not merely unfrozen at load. A module that memoises on its
-- first call satisfies every assertion above while still being wrong, so the
-- redirect is moved a second time and the path has to follow it.
local MOVED_HOME = harness.sandbox_root .. "/state-moved"
vim.fn.mkdir(MOVED_HOME, "p", tonumber("700", 8))
vim.env.XDG_STATE_HOME = MOVED_HOME

local moved = state.path()
harness.expect(
  is_inside(moved, MOVED_HOME),
  "path() still resolved to %s after $XDG_STATE_HOME moved to %s — the path is cached on first call rather "
    .. "than resolved per call",
  moved,
  MOVED_HOME
)

vim.env.XDG_STATE_HOME = STATE_HOME

-- 3. publish() is temp-file-plus-rename, asserted at the call level: the final
-- path must never be opened for truncation, because a reader sampling across a
-- run of role flips would observe a partial document.
local renames, truncations = {}, {}
local real = {
  fs_rename = vim.uv.fs_rename,
  fs_open = vim.uv.fs_open,
  io_open = io.open,
  writefile = vim.fn.writefile,
}

vim.uv.fs_rename = function(from, to, ...)
  renames[#renames + 1] = { from = from, to = to }
  return real.fs_rename(from, to, ...)
end
vim.uv.fs_open = function(target, flags, ...)
  if type(flags) == "string" and flags:find("w") then
    truncations[#truncations + 1] = target
  end
  return real.fs_open(target, flags, ...)
end
-- Deliberate, scoped and restored below. luacheck flags any write to a stdlib
-- field (122); here it is how the check observes which path was truncated.
-- luacheck: push ignore 122
io.open = function(name, mode)
  if type(mode) == "string" and mode:find("w") then
    truncations[#truncations + 1] = name
  end
  return real.io_open(name, mode)
end
-- luacheck: pop
-- Forwarded through `...` rather than a named third parameter. The vim.fn bridge
-- turns an explicit Lua nil into v:null, so re-calling with a fixed arity would
-- make `writefile(lines, path)` fail with E5060 inside the wrapper — an
-- interception that breaks the code it is observing.
vim.fn.writefile = function(lines, fname, ...)
  local flags = ...
  if not (type(flags) == "string" and flags:find("a")) then
    truncations[#truncations + 1] = fname
  end
  return real.writefile(lines, fname, ...)
end

state.publish({ role = "navigator", test_command = "mise run test" })

vim.uv.fs_rename = real.fs_rename
vim.uv.fs_open = real.fs_open
-- luacheck: push ignore 122
io.open = real.io_open
-- luacheck: pop
vim.fn.writefile = real.writefile

local landed = false
for _, rename in ipairs(renames) do
  if resolved(rename.to) == resolved(path) then
    landed = true
    harness.expect(
      resolved(rename.from) ~= resolved(path),
      "publish() renamed %s onto itself — the record must be built somewhere else and moved into place",
      rename.from
    )
  end
end
harness.expect(
  landed,
  "publish() never renamed anything onto %s — writing the record in place leaves a window where a reader "
    .. "observes a partial document, and a torn file reads as live-but-role-unreadable, refusing read-only work",
  path
)

for _, opened in ipairs(truncations) do
  harness.expect(
    resolved(opened) ~= resolved(path),
    "publish() opened the final path %s for truncation — that is exactly the torn-read window temp-plus-rename "
      .. "exists to close",
    opened
  )
end

-- 7. The record carries a schema version and the owner pid, or a file from a
-- previous codriver version parses as a role and a pid-recycled file reads live.
local written = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
harness.expect(
  written.schema ~= nil,
  "the published record carries no schema version — a file written by a previous codriver would parse as a role"
)
harness.expect_eq(
  written.pid,
  vim.uv.os_getpid(),
  "the published record must carry its owner pid, or a pid-recycled file reads as live"
)
harness.expect_eq(written.role, "navigator", "the published record must carry the role")
harness.expect_eq(
  written.test_command,
  "mise run test",
  "the published record must carry the resolved test_command — the state file is the only channel that reaches "
    .. "the hook subprocess, which runs under `nvim --clean -l` with codriver's config unreachable"
)
local SCHEMA = written.schema

-- 7b. bash_allow round-trips through the same JSON state file, unchanged.
state.publish({ role = "navigator", bash_allow = { heads = { "foo" }, git_subcommands = { "stash" } } })
local written_allow = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
harness.expect_eq(
  written_allow.bash_allow and written_allow.bash_allow.heads and written_allow.bash_allow.heads[1],
  "foo",
  "the published record must carry bash_allow.heads unchanged"
)
harness.expect_eq(
  written_allow.bash_allow and written_allow.bash_allow.git_subcommands and written_allow.bash_allow.git_subcommands[1],
  "stash",
  "the published record must carry bash_allow.git_subcommands unchanged"
)

-- 4. read() keeps its failure modes apart. The caller allows on missing and
-- denies on corrupt, so one value for both makes c-7 and no_session_behaviour
-- indistinguishable.
local missing_record, missing_reason = state.read(STATE_HOME .. "/codriver/no-such-session.json")
harness.expect_eq(missing_record, nil, "read(<missing>) must not return a record")

local corrupt_path = STATE_HOME .. "/codriver/corrupt.json"
harness.write(corrupt_path, "{ truncated mid-jso")
local corrupt_record, corrupt_reason = state.read(corrupt_path)
harness.expect_eq(corrupt_record, nil, "read(<not json>) must not return a record")

harness.expect(
  missing_reason ~= nil and corrupt_reason ~= nil and missing_reason ~= corrupt_reason,
  "read() collapsed its failure modes: missing gave %s and unparsable gave %s — the caller allows on the first "
    .. "and denies on the second",
  vim.inspect(missing_reason),
  vim.inspect(corrupt_reason)
)

-- 8. An absent test_command reads back as nil, not as an empty string and not as
-- vim.NIL. An empty command would match t-2's empty-command refusal instead of
-- disabling the allowance entirely.
state.publish({ role = "driver" })
local without = state.read(state.path())
harness.expect_eq(
  without.test_command,
  nil,
  "a record published with no test_command must read back as nil — an empty string would match t-2's "
    .. "empty-command refusal rather than disabling the allowance"
)
harness.expect_eq(
  without.bash_allow,
  nil,
  "a record published with no bash_allow must read back as nil, not as vim.NIL"
)
harness.expect_eq(without.role, "driver", "publish() must not drop the fields it was given")

-- 5. Liveness is the owning process, not the file. A killed nvim leaving a
-- readable navigator record behind must not deny every write in the repo
-- forever — that record is no session at all.
local stale_pid = dead_pid()
local stale_path = STATE_HOME .. "/codriver/" .. stale_pid .. ".json"
harness.write(stale_path, vim.json.encode({ schema = SCHEMA, pid = stale_pid, role = "navigator" }))

local stale = state.probe({ CODRIVER_STATE_FILE = stale_path })
harness.expect(
  stale.live == false,
  "probe() reported live for a record whose owning pid %d is dead — liveness is kill(pid, 0), not file "
    .. "existence, or a killed editor denies every write in this repo forever",
  stale_pid
)

-- 6. A live owner with an unreadable record is a third state, distinct from
-- no-session-at-all. Without it c-7 cannot fire.
harness.write(state.path(), "{ truncated mid-jso")
local unreadable = state.probe({ CODRIVER_STATE_FILE = state.path() })
harness.expect_eq(
  unreadable.live,
  true,
  "a corrupt record whose owning process is alive must still report live — reporting false collapses c-7 into "
    .. "no_session_behaviour and the tool call is allowed instead of refused"
)
harness.expect_eq(
  unreadable.role,
  nil,
  "a corrupt record must report role = nil, the third result distinct from no-session-at-all"
)

-- The remaining two of the three states, so none of them collapse into another.
local absent = state.probe({})
harness.expect_eq(
  absent.live,
  false,
  "an environment with no CODRIVER_STATE_FILE is no session — the hook lives in the repo permanently and must "
    .. "get out of the way of a plain `claude` run"
)

state.publish({
  role = "navigator",
  test_command = "mise run test",
  bash_allow = { heads = { "foo" } },
})
local live = state.probe({ CODRIVER_STATE_FILE = state.path() })
harness.expect_eq(live.live, true, "a readable record whose owner is alive must report live")
harness.expect_eq(live.role, "navigator", "probe() must surface the published role")
harness.expect_eq(
  live.test_command,
  "mise run test",
  "probe() must surface the test_command — t-5 has no other route to join it to the matcher"
)
harness.expect_eq(
  live.bash_allow and live.bash_allow.heads and live.bash_allow.heads[1],
  "foo",
  "probe() must surface bash_allow when the on-disk record carries it"
)

-- clear() removes the record. The owning process is still up, so this is
-- live-but-role-unreadable rather than no-session — the same reading t-11
-- asserts for a state file deleted underneath a live instance.
state.clear()
harness.expect_eq(vim.fn.filereadable(state.path()), 0, "clear() must remove the session record")

local cleared = state.probe({ CODRIVER_STATE_FILE = state.path() })
harness.expect_eq(
  cleared.live,
  true,
  "a deleted record whose owning process is still alive is live-but-role-unreadable, not no-session — the pid "
    .. "in the filename is what answers the liveness question once the contents are gone"
)
harness.expect_eq(cleared.role, nil, "a deleted record must report role = nil")

harness.ok(
  "the state path is sandbox-resolved and outside the tree, publish is temp-plus-rename carrying schema/pid/"
    .. "test_command/bash_allow, read keeps missing and corrupt apart, and probe answers in three states keyed on "
    .. "kill(pid, 0)"
)
