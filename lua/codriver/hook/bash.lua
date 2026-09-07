local M = {}

local ALLOWED_HEADS = {
  rg = true,
  git = true,
  ls = true,
  cat = true,
  head = true,
  wc = true,
}

local GIT_ALLOWED_SUBCOMMANDS = {
  status = true,
  log = true,
  diff = true,
  show = true,
  blame = true,
  ["ls-files"] = true,
  ["rev-parse"] = true,
}

local function trimHelper(text)
  return text:match("^%s*(.-)%s*$")
end

local function splitHelper(text)
  local chunks = {}
  for chunk in text:gmatch("[^|;&]+") do
    table.insert(chunks, trimHelper(chunk))
  end
  return chunks
end

local function headToken(segment)
  local seg = trimHelper(segment):match("^(%S+)")
  if type(seg) == "string" then
    return seg
  end

  return nil
end

local function segmentToken(segment)
  local seg = trimHelper(segment):match("^%S+%s+(%S+)")
  return seg
end

local function hasRedirection(command)
  if command:find(">") then
    return true
  end

  return false
end

local function hasSubstitution(command)
  if command:find("$(", 1, true) then
    return true
  end
  if command:find("`", 1, true) then
    return true
  end
  if command:find("<(", 1, true) then
    return true
  end
  return false
end

local function segmentAllowed(segment, heads, git_subcommands)
  local head = headToken(segment)
  if type(head) == "string" and heads[head] then
    if head == "git" then
      local second = segmentToken(segment)
      if type(second) == "string" and git_subcommands[second] then
        return true
      end
    else
      return true
    end
  end

  return false
end

---Copy `defaults` into a new set and add every string in `additions`. Never
---mutates `defaults` — the hardcoded floor stays intact across calls.
---@param defaults table<string, true>
---@param additions string[]|nil
---@return table<string, true>
local function merge_set(defaults, additions)
  local merged = {}
  for key in pairs(defaults) do
    merged[key] = true
  end
  for _, item in ipairs(additions or {}) do
    merged[item] = true
  end
  return merged
end

---The hardcoded heads/git-subcommand defaults merged with a session's
---`bash_allow` additions — additive only, never replacing the defaults.
---@param bash_allow { heads: string[]|nil, git_subcommands: string[]|nil }|nil
---@return { heads: table<string, true>, git_subcommands: table<string, true> }
function M.effective_allowlist(bash_allow)
  bash_allow = bash_allow or {}
  return {
    heads = merge_set(ALLOWED_HEADS, bash_allow.heads),
    git_subcommands = merge_set(GIT_ALLOWED_SUBCOMMANDS, bash_allow.git_subcommands),
  }
end

function M.allows(command, test_command, bash_allow)
  if type(test_command) == "string" then
    if trimHelper(command) == trimHelper(test_command) then
      return true
    end
  end
  if hasRedirection(command) then
    return false
  end
  if hasSubstitution(command) then
    return false
  end
  local segs = splitHelper(command)
  if #segs == 0 then
    return false
  end
  local allowlist = M.effective_allowlist(bash_allow)
  for _, seg in ipairs(segs) do
    if not segmentAllowed(seg, allowlist.heads, allowlist.git_subcommands) then
      return false
    end
  end

  return true
end
return M
