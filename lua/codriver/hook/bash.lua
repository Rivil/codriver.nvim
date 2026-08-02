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

local function segmentAllowed(segment)
  local head = headToken(segment)
  if type(head) == "string" and ALLOWED_HEADS[head] then
    if head == "git" then
      local second = segmentToken(segment)
      if type(second) == "string" and GIT_ALLOWED_SUBCOMMANDS[second] then
        return true
      end
    else
      return true
    end
  end

  return false
end

function M.allows(command, test_command)
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
  for _, seg in ipairs(segs) do
    if not segmentAllowed(seg) then
      return false
    end
  end

  return true
end
return M
