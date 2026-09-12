require("tests.busted_setup")

local state = require("codriver.hook.state")

-- hook.state's filesystem/process boundary (vim.fn.stdpath/mkdir/writefile/
-- filereadable/readfile/delete/fnamemodify, vim.uv.os_getpid/fs_rename/kill,
-- vim.json.encode/decode) is faked locally per-spec, the same way
-- ownership_spec.lua fakes it for codriver.ownership — see that file's note
-- on why busted_setup.lua's shared stub stays deliberately minimal. This is
-- the first busted-level spec for hook.state: everything else lives in
-- tests/nvim/hook_state_check.lua against the real filesystem/pid contract.
--
-- vim.json here is not a real JSON codec, just enough of one (string/number
-- scalars, flat string arrays, one level of nesting for bash_allow) to prove
-- a real publish()/read() round-trip without pulling in a JSON library.

local STATE_ROOT = "/tmp/hook-state-spec"
local PID = 4242

local function encode_string(s)
  return '"' .. s:gsub('"', '\\"') .. '"'
end

local function encode_string_array(arr)
  local parts = {}
  for _, item in ipairs(arr) do
    table.insert(parts, encode_string(item))
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function encode(record)
  local parts = { ('"schema":%d'):format(record.schema), ('"pid":%d'):format(record.pid) }
  if record.role then
    table.insert(parts, ('"role":%s'):format(encode_string(record.role)))
  end
  if record.test_command then
    table.insert(parts, ('"test_command":%s'):format(encode_string(record.test_command)))
  end
  if record.bash_allow then
    local inner = {}
    if record.bash_allow.heads then
      table.insert(inner, ('"heads":%s'):format(encode_string_array(record.bash_allow.heads)))
    end
    if record.bash_allow.git_subcommands then
      table.insert(inner, ('"git_subcommands":%s'):format(encode_string_array(record.bash_allow.git_subcommands)))
    end
    table.insert(parts, ('"bash_allow":{%s}'):format(table.concat(inner, ",")))
  end
  if record.write_allow then
    table.insert(parts, ('"write_allow":%s'):format(encode_string_array(record.write_allow)))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function decode_string_array(text)
  local arr = {}
  for item in text:gmatch('"([^"]*)"') do
    table.insert(arr, item)
  end
  return arr
end

local function decode(text)
  local record = {}
  record.schema = tonumber(text:match('"schema":(%d+)'))
  record.pid = tonumber(text:match('"pid":(%d+)'))
  record.role = text:match('"role":"([^"]*)"')
  record.test_command = text:match('"test_command":"([^"]*)"')

  local bash_block = text:match('"bash_allow":{(.-)}')
  if bash_block then
    record.bash_allow = {}
    local heads_block = bash_block:match('"heads":(%[[^%]]*%])')
    if heads_block then
      record.bash_allow.heads = decode_string_array(heads_block)
    end
    local git_block = bash_block:match('"git_subcommands":(%[[^%]]*%])')
    if git_block then
      record.bash_allow.git_subcommands = decode_string_array(git_block)
    end
  end

  local write_block = text:match('"write_allow":(%[[^%]]*%])')
  if write_block then
    record.write_allow = decode_string_array(write_block)
  end

  return record
end

---An in-memory stand-in for the state file on disk, keyed by path. Returned
---so a test can plant or inspect a path directly, the same way ownership_spec
---reaches into its own fake store.
local function set_fs()
  local files = {}

  _G.vim.fn = {
    stdpath = function()
      return STATE_ROOT
    end,
    mkdir = function()
      return 1
    end,
    fnamemodify = function(path, modifier)
      if modifier == ":h" then
        return path:match("^(.*)/[^/]+$") or path
      elseif modifier == ":t:r" then
        local tail = path:match("([^/]+)$") or path
        return (tail:gsub("%.[^.]*$", ""))
      end
      return path
    end,
    writefile = function(lines, path)
      files[path] = lines[1]
    end,
    filereadable = function(path)
      return files[path] and 1 or 0
    end,
    readfile = function(path)
      return { files[path] }
    end,
    delete = function(path)
      files[path] = nil
      return 0
    end,
  }
  _G.vim.uv = {
    os_getpid = function()
      return PID
    end,
    fs_rename = function(from, to)
      files[to] = files[from]
      files[from] = nil
      return true
    end,
    kill = function(pid)
      return pid == PID
    end,
  }
  _G.vim.json = { encode = encode, decode = decode }

  return files
end

describe("codriver.hook.state", function()
  local files

  before_each(function()
    _G.reset_vim_stub()
    files = set_fs()
  end)

  after_each(function()
    _G.vim.fn = nil
    _G.vim.uv = nil
    _G.vim.json = nil
  end)

  it("round-trips a write_allow value through publish/read unchanged, the same as bash_allow", function()
    state.publish({
      role = "navigator",
      bash_allow = { heads = { "gh" }, git_subcommands = { "stash" } },
      write_allow = { "notes", "scratch/logs" },
    })

    local record = state.read(state.path())

    assert.are.same({ heads = { "gh" }, git_subcommands = { "stash" } }, record.bash_allow)
    assert.are.same({ "notes", "scratch/logs" }, record.write_allow)
  end)

  it("includes write_allow in probe()'s live-session table, exactly as it already includes bash_allow", function()
    state.publish({ role = "navigator", write_allow = { "notes" } })

    local live = state.probe({ CODRIVER_STATE_FILE = state.path() })

    assert.is_true(live.live)
    assert.are.same({ "notes" }, live.write_allow)
  end)

  it("leaves an unrelated file on disk untouched by state.clear()", function()
    state.publish({ role = "navigator", write_allow = { "notes" } })
    files["/some/allowed/path.md"] = "hello"

    state.clear()

    assert.is_nil(files[state.path()], "the state file itself must be removed")
    assert.are.equal("hello", files["/some/allowed/path.md"], "clear() must not touch any other file")
  end)
end)
