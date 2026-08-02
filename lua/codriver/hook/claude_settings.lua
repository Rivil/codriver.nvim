local M = {}

-- `merge` and `encode` are pure table transforms with no vim.* surface, so they
-- are busted-testable. `install` is the atomic read-merge-write shell around
-- them and needs real filesystem primitives, so it lives here but is only
-- exercised headlessly (tests/nvim/hook_settings_check.lua).

local HOOK_MARKER = "codriver%-hook%.lua"

---True when `entry` is a PreToolUse entry codriver itself registered, identified
---by the hook script's basename rather than a full command match — a moved
---plugin root must still be recognised as stale.
---@param entry table
---@return boolean
local function is_codriver_entry(entry)
  if type(entry) ~= "table" or type(entry.hooks) ~= "table" then
    return false
  end
  for _, h in ipairs(entry.hooks) do
    if type(h) == "table" and type(h.command) == "string" and h.command:find(HOOK_MARKER) then
      return true
    end
  end
  return false
end

---Pure table transform: ensure `existing` has exactly one PreToolUse entry
---registering `command`, replacing any stale codriver entry, and leaving every
---other key and entry untouched.
---@param existing table|nil
---@param command string
---@return table
function M.merge(existing, command)
  local doc = {}
  if type(existing) == "table" then
    for k, v in pairs(existing) do
      doc[k] = v
    end
  end

  local pre_tool_use = {}
  local existing_hooks = doc.hooks
  local existing_pre = type(existing_hooks) == "table" and existing_hooks.PreToolUse or nil
  if type(existing_pre) == "table" then
    for _, entry in ipairs(existing_pre) do
      if not is_codriver_entry(entry) then
        table.insert(pre_tool_use, entry)
      end
    end
  end

  table.insert(pre_tool_use, {
    matcher = "*",
    hooks = { { type = "command", command = command } },
  })

  local hooks = {}
  if type(existing_hooks) == "table" then
    for k, v in pairs(existing_hooks) do
      hooks[k] = v
    end
  end
  hooks.PreToolUse = pre_tool_use
  doc.hooks = hooks

  return doc
end

-- Key paths (dot-joined, array indices skipped) whose value must render as a
-- JSON array even when empty. vim.json / a generic "does it look like a
-- sequence" check cannot tell an empty array from an empty object apart, so
-- the settings schema's known array-shaped keys are named explicitly here.
local ARRAY_TYPE_PATHS = {
  ["permissions.allow"] = true,
  ["permissions.deny"] = true,
  ["permissions.ask"] = true,
  ["hooks.PreToolUse"] = true,
  ["hooks.PostToolUse"] = true,
  ["hooks.PreToolUse.hooks"] = true,
  ["hooks.PostToolUse.hooks"] = true,
}

local INDENT = "  "

local function indent(level)
  return INDENT:rep(level)
end

local function child_path(parent_path, key)
  local copy = {}
  for i, v in ipairs(parent_path) do
    copy[i] = v
  end
  copy[#copy + 1] = key
  return copy
end

local function json_string(s)
  local escaped = s:gsub('[%c"\\]', function(c)
    if c == '"' then
      return '\\"'
    elseif c == "\\" then
      return "\\\\"
    elseif c == "\n" then
      return "\\n"
    elseif c == "\t" then
      return "\\t"
    elseif c == "\r" then
      return "\\r"
    end
    return ("\\u%04x"):format(c:byte())
  end)
  return '"' .. escaped .. '"'
end

---True when `t` is a non-empty Lua sequence (unambiguous — only the empty case
---needs schema knowledge to disambiguate array from object).
---@param t table
---@return boolean
local function is_array_like(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  if n == 0 then
    return false
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return true
end

local encode_value, encode_array, encode_object

encode_array = function(items, level)
  if #items == 0 then
    return "[]"
  end
  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, indent(level + 1) .. encode_value(item, level + 1, {}))
  end
  return "[\n" .. table.concat(lines, ",\n") .. "\n" .. indent(level) .. "]"
end

encode_object = function(doc, level, type_path)
  local keys = {}
  for k in pairs(doc) do
    table.insert(keys, k)
  end
  table.sort(keys)
  if #keys == 0 then
    return "{}"
  end
  local lines = {}
  for _, k in ipairs(keys) do
    local value = encode_value(doc[k], level + 1, child_path(type_path, k))
    table.insert(lines, indent(level + 1) .. json_string(k) .. ": " .. value)
  end
  return "{\n" .. table.concat(lines, ",\n") .. "\n" .. indent(level) .. "}"
end

encode_value = function(value, level, type_path)
  local t = type(value)
  if t == "boolean" then
    return tostring(value)
  elseif t == "number" then
    if value == math.floor(value) then
      return ("%d"):format(value)
    end
    return tostring(value)
  elseif t == "string" then
    return json_string(value)
  elseif t == "table" then
    local forced = ARRAY_TYPE_PATHS[table.concat(type_path, ".")]
    local as_array
    if forced ~= nil then
      as_array = forced
    else
      as_array = is_array_like(value)
    end
    if as_array then
      return encode_array(value, level)
    end
    return encode_object(value, level, type_path)
  end
  error(("codriver.hook.claude_settings: cannot encode value of type %s"):format(t))
end

---Deterministic serializer: sorted keys, fixed 2-space indent, array-ness
---preserved for the settings schema's known array paths.
---@param doc table
---@return string
function M.encode(doc)
  return encode_value(doc, 0, {})
end

---Atomic read-merge-write of the Claude settings file at `path`, registering
---`command` as codriver's PreToolUse hook. Refuses (raises, naming the path)
---rather than overwriting a file that fails to parse as JSON.
---@param path string
---@param command string
function M.install(path, command)
  local existing = nil
  if vim.fn.filereadable(path) == 1 then
    local raw = table.concat(vim.fn.readfile(path), "\n")
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
      error(("codriver: refusing to overwrite malformed settings file: %s"):format(path))
    end
    existing = decoded
  end

  local doc = M.merge(existing, command)
  local encoded = M.encode(doc)

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p", tonumber("700", 8))
  local tmp = path .. ".tmp"
  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), tmp)
  assert(vim.uv.fs_rename(tmp, path))
end

return M
