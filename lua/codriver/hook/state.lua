local M = {}

local SCHEMA = 1
function M.path()
  return ("%s/codriver/%d.json"):format(vim.fn.stdpath("state"), vim.uv.os_getpid())
end

function M.publish(record)
  local target = M.path()
  vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p", tonumber("700", 8))

  local tmp = target .. ".tmp"
  vim.fn.writefile({
    vim.json.encode({
      schema = SCHEMA,
      pid = vim.uv.os_getpid(),
      role = record.role,
      test_command = record.test_command,
      bash_allow = record.bash_allow,
    }),
  }, tmp)

  assert(vim.uv.fs_rename(tmp, target))
end

function M.read(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "missing"
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then
    return nil, "corrupt"
  end

  if decoded.test_command == vim.NIL then
    decoded.test_command = nil
  end
  if decoded.bash_allow == vim.NIL then
    decoded.bash_allow = nil
  end
  return decoded
end

function M.probe(env)
  local path = env and env.CODRIVER_STATE_FILE
  if type(path) ~= "string" or path == "" then
    return { live = false }
  end

  local pid = tonumber(vim.fn.fnamemodify(path, ":t:r"))
  if not pid or not vim.uv.kill(pid, 0) then
    return { live = false }
  end

  local record = M.read(path)
  if not record or record.schema ~= SCHEMA or record.pid ~= pid then
    return { live = true }
  end

  return { live = true, role = record.role, test_command = record.test_command, bash_allow = record.bash_allow }
end

function M.clear()
  vim.fn.delete(M.path())
end

return M
