require("tests.busted_setup")

-- Pure string work over README.md, no vim.* surface — same lane as
-- hook_bash_spec.lua. This exists because /dross-verify found the Options
-- section's documentation criteria (c-2, c-4) had no test: nothing failed
-- when README.md drifted out of sync with the actual config surface.

---@return string
local function read_readme()
  local here = debug.getinfo(1, "S").source:sub(2) -- strip the leading "@"
  local root = here:match("(.*/)tests/codriver/readme_spec%.lua$") or "./"
  local path = root .. "README.md"
  local f = assert(io.open(path, "r"), "could not open " .. path)
  local content = f:read("*a")
  f:close()
  return content
end

describe("README Options section", function()
  local readme = read_readme()
  local lowered = readme:lower()

  it("documents bash_allow's shape and additive-only behaviour", function()
    assert.is_truthy(readme:find("bash_allow", 1, true), "README must mention bash_allow")
    assert.is_truthy(readme:find("heads = {", 1, true), "README must show the bash_allow.heads shape")
    assert.is_truthy(readme:find("git_subcommands", 1, true), "README must show bash_allow.git_subcommands")
    assert.is_truthy(lowered:find("additive", 1, true), "README must state bash_allow is additive-only")
  end)

  it("documents test_command's exact-match exemption from the Bash allowlist", function()
    assert.is_truthy(readme:find("test_command", 1, true), "README must mention test_command")
    assert.is_truthy(lowered:find("exact match", 1, true), "README must state test_command is matched exactly")
    assert.is_truthy(lowered:find("bash allowlist", 1, true), "README must tie test_command to the Bash allowlist")
  end)

  it("documents write_allow's shape, segment-boundary matching, and Bash exclusion", function()
    assert.is_truthy(readme:find("write_allow = {", 1, true), "README must show write_allow's flat string-list shape")
    assert.is_truthy(
      lowered:find("segment boundary", 1, true),
      "README must state write_allow is prefix-matched with a segment boundary"
    )
    assert.is_truthy(lowered:find("not glob", 1, true), "README must state write_allow does not support glob")
    assert.is_truthy(
      lowered:find("does not extend to bash", 1, true) or lowered:find("governed solely by `bash_allow`", 1, true),
      "README must state write_allow does not extend to Bash"
    )
  end)

  it("lists all four Options keys in one coherent example block, in order", function()
    local options_start = readme:find("### Options", 1, true)
    assert.is_truthy(options_start, "README must have an Options section")

    -- Scoped to the ```lua example itself, not the surrounding prose: prose
    -- ahead of the fence explains the claudecode nesting before the code
    -- ever mentions auto_start, which would otherwise trip the ordering
    -- check on wording that isn't the "one example block" the criterion means.
    local fence_start = readme:find("```lua", options_start, true)
    assert.is_truthy(fence_start, "README must have a ```lua example under Options")
    local fence_end = readme:find("```", fence_start + 6, true)
    assert.is_truthy(fence_end, "the ```lua example under Options must close")
    local block = readme:sub(fence_start, fence_end)

    local auto_start_pos = block:find("auto_start", 1, true)
    local claudecode_pos = block:find("claudecode", 1, true)
    local test_command_pos = block:find("test_command", 1, true)
    local bash_allow_pos = block:find("bash_allow", 1, true)

    assert.is_truthy(auto_start_pos, "the example block must mention auto_start")
    assert.is_truthy(claudecode_pos, "the example block must mention claudecode")
    assert.is_truthy(test_command_pos, "the example block must mention test_command")
    assert.is_truthy(bash_allow_pos, "the example block must mention bash_allow")

    assert.is_true(auto_start_pos < claudecode_pos, "auto_start must appear before claudecode")
    assert.is_true(claudecode_pos < test_command_pos, "claudecode must appear before test_command")
    assert.is_true(test_command_pos < bash_allow_pos, "test_command must appear before bash_allow")
  end)
end)
