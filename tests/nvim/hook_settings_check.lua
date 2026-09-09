-- Merge codriver's PreToolUse hook into a Claude settings file — the atomic
-- read-merge-write half of claude_settings.lua that needs real filesystem
-- primitives. The pure merge()/encode() transforms are covered by
-- tests/codriver/hook_claude_settings_spec.lua under busted; this check is
-- only about install()'s I/O contract.

local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local harness = dofile(here .. "/harness.lua").setup()

local claude_settings = require("codriver.hook.claude_settings")

local COMMAND = "nvim --clean -l /plugin/root/scripts/codriver-hook.lua"

-- 1. install() creates the file, registering the wildcard matcher and command.
local settings_path = harness.sandbox_root .. "/project/.claude/settings.local.json"
claude_settings.install(settings_path, COMMAND)

harness.expect_eq(vim.fn.filereadable(settings_path), 1, "install() must create the settings file")
local doc = vim.json.decode(table.concat(vim.fn.readfile(settings_path), "\n"))
harness.expect_eq(doc.hooks.PreToolUse[1].matcher, "*", "the registered matcher must be the literal wildcard")
harness.expect_eq(
  doc.hooks.PreToolUse[1].hooks[1].command,
  COMMAND,
  "the registered command must be the one install() was given"
)

-- 2. install() is atomic: a rename that cannot land must leave the original
-- truncated or gone neither — the file before and after must be byte-identical.
local before = table.concat(vim.fn.readfile(settings_path), "\n")
local real_rename = vim.uv.fs_rename
vim.uv.fs_rename = function(...)
  return nil, "EACCES: permission denied"
end
local rename_ok = pcall(claude_settings.install, settings_path, "a completely different command")
vim.uv.fs_rename = real_rename

harness.expect(rename_ok == false, "install() must raise when the rename cannot land, not continue silently")
local after = table.concat(vim.fn.readfile(settings_path), "\n")
harness.expect_eq(after, before, "a failed rename must leave the original settings file untouched")

-- 3. Malformed existing JSON is refused, not silently overwritten — the user's
-- hand-written allow list would otherwise be destroyed.
local malformed_path = harness.sandbox_root .. "/malformed/settings.local.json"
harness.write(malformed_path, "{ not actually json")

local install_ok, install_err = pcall(claude_settings.install, malformed_path, COMMAND)
harness.expect(install_ok == false, "install() must refuse a malformed existing settings file rather than overwrite it")
harness.expect(
  type(install_err) == "string" and install_err:find(malformed_path, 1, true) ~= nil,
  "the refusal must name the offending path — got %s",
  vim.inspect(install_err)
)
local untouched = table.concat(vim.fn.readfile(malformed_path), "\n")
harness.expect_eq(untouched, "{ not actually json", "a refused install() must leave the malformed file byte-identical")

-- 4. install() never drifts outside the path it was given. Every headless check
-- runs with cwd at the repo root, so a drifting path would arm enforcement
-- against the developer's own session.
local real_settings = harness.repo_root .. "/.claude/settings.local.json"
local function snapshot()
  if vim.fn.filereadable(real_settings) == 1 then
    return table.concat(vim.fn.readfile(real_settings), "\n")
  end
  return nil
end

local real_before = snapshot()
claude_settings.install(harness.sandbox_root .. "/another-project/.claude/settings.local.json", COMMAND)
local real_after = snapshot()

harness.expect_eq(
  real_after,
  real_before,
  "install() must never write under this repository's own .claude/ regardless of the target path it was given"
)

harness.ok(
  "install() atomically read-merge-writes the settings file, refuses a malformed existing file by name without "
    .. "touching it, and never drifts outside the path it was given"
)
