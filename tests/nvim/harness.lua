-- Shared harness for the headless Neovim checks in this directory.
--
-- Every `*_check.lua` here runs in its own `nvim --clean --headless -l` process
-- (see `mise run test-nvim`). They all start the same way:
--
--   local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
--   local harness = dofile(here .. "/harness.lua").setup()
--
-- It is loaded with `dofile` rather than `require` because tests/nvim is not on
-- any package path, and putting it there would make the harness itself look
-- like a plugin module to the very loader these checks exercise.
--
-- Two jobs:
--
--   * Assertions that are *fatal*. A check that printed "expected X, got Y" and
--     carried on would still exit 0, and the runner would report it as a pass.
--     So every assertion here ends the process with a non-zero status.
--
--   * A sandboxed HOME/CLAUDE_CONFIG_DIR. The vendored lockfile module freezes
--     `lock_dir` at module load from $CLAUDE_CONFIG_DIR, and these checks delete
--     lockfiles. Pointed at the real ~/.claude/ide, that would unlink a live
--     session's lockfile out from under a real editor — so the harness refuses
--     to run unless the lock dir is a scratch directory under the system temp
--     root, and refuses again if it is not empty before anything has started.
--
-- Because the assertions exit immediately, a check that creates files outside
-- its own temp dir must gather its evidence first, clean up, and only then
-- assert on what it gathered.

local M = {}

local script = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))

---Repository root. tests/nvim/harness.lua sits three levels down.
M.repo_root = vim.fn.fnamemodify(script, ":p:h:h:h")

---The real $HOME, captured before `setup()` redirects it. Subprocesses that
---read the developer's configuration — `mise` above all — have to be handed
---this back explicitly, or they resolve their config out of an empty sandbox.
M.real_home = vim.env.HOME

---Name of the running check, for failure messages.
M.name = vim.fn.fnamemodify((_G.arg and _G.arg[0]) or script, ":t")

---Sandbox root for this process. Set by `setup()`.
M.sandbox_root = nil

---Lock directory the vendored lockfile module will compute. Set by `setup()`.
---Kept in the vendored module's own form (`expand()`, symlinks unresolved) so a
---check can compare paths against it literally.
M.lock_dir = nil

---Absolute, symlink-resolved, trailing-slash-free form of a path.
---@param path string
---@return string
local function resolved(path)
  return (vim.fn.resolve(vim.fn.fnamemodify(vim.fn.expand(path), ":p")):gsub("/+$", ""))
end

---True when `path` is inside `dir`.
---@param path string
---@param dir string
---@return boolean
local function is_inside(path, dir)
  return path:sub(1, #dir + 1) == dir .. "/"
end

---Abort the check with a non-zero exit status. Never returns.
---
---Do not wrap harness assertions in `pcall` — this exits the process, and a
---check that swallows it reports a failure as a pass.
---@param fmt string
---@param ... any
function M.fail(fmt, ...)
  local msg = select("#", ...) > 0 and fmt:format(...) or fmt
  io.stderr:write(("%s: %s\n"):format(M.name, msg))
  io.stderr:flush()
  vim.cmd("cquit 1")
  -- Unreachable in practice; a backstop if :cquit is ever prevented from
  -- running, so a failed assertion can never exit 0.
  os.exit(1, false)
end

---@param cond any
---@param fmt string
---@param ... any
function M.expect(cond, fmt, ...)
  if not cond then
    M.fail(fmt, ...)
  end
  return cond
end

---@param actual any
---@param expected any
---@param what string
function M.expect_eq(actual, expected, what)
  if actual ~= expected then
    M.fail("%s: expected %s, got %s", what, vim.inspect(expected), vim.inspect(actual))
  end
end

---@param haystack string
---@param needle string literal substring
---@param what string
function M.expect_contains(haystack, needle, what)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    M.fail(
      "%s: expected to contain %s\n--- actual ---\n%s\n--------------",
      what,
      vim.inspect(needle),
      tostring(haystack)
    )
  end
end

---@param haystack string
---@param needle string literal substring
---@param what string
function M.expect_not_contains(haystack, needle, what)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    M.fail("%s: expected NOT to contain %s\n--- actual ---\n%s\n--------------", what, vim.inspect(needle), haystack)
  end
end

---@param haystack string
---@param pattern string Lua pattern
---@param what string
function M.expect_match(haystack, pattern, what)
  if type(haystack) ~= "string" or not haystack:match(pattern) then
    M.fail(
      "%s: expected to match %s\n--- actual ---\n%s\n--------------",
      what,
      vim.inspect(pattern),
      tostring(haystack)
    )
  end
end

---Report the check as passed. Purely informational — the exit status is what
---the runner reads.
---@param fmt string
---@param ... any
function M.ok(fmt, ...)
  local msg = select("#", ...) > 0 and fmt:format(...) or fmt
  print(("%s: %s"):format(M.name, msg))
end

---Write `contents` to `path`, creating parent directories.
---@param path string
---@param contents string
function M.write(path, contents)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(contents, "\n"), path)
end

---Run a command to completion.
---
---`opts.env` entries are merged over the inherited environment. Anything that
---reads the developer's configuration needs `HOME = harness.real_home` passed
---back, because `setup()` has pointed $HOME at an empty sandbox.
---@param cmd string[]
---@param opts table|nil
---@return vim.SystemCompleted
function M.run(cmd, opts)
  return vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
end

---Run the REGISTERED PreToolUse hook command against `payload`, JSON-encoded
---onto its stdin exactly as Claude Code feeds a hook — the same command
---codriver's own claude_settings.install() writes into .claude/settings.local.json
---(`nvim --clean -l <repo>/scripts/codriver-hook.lua`). Every headless check
---in t-10..t-14 drives the hook through this one spawner rather than growing
---its own, so a change to the registered command only has to land here.
---@param payload table
---@param env table|nil merged over the inherited environment, see M.run
---@return { code: integer, stdout: string, stderr: string }
function M.run_hook(payload, env)
  local result = M.run({ "nvim", "--clean", "-l", M.repo_root .. "/scripts/codriver-hook.lua" }, {
    env = env,
    stdin = vim.json.encode(payload),
  })
  return { code = result.code, stdout = result.stdout, stderr = result.stderr }
end

---Lockfiles currently in the sandboxed lock directory.
---@return string[]
function M.lock_files()
  return vim.fn.glob(M.lock_dir .. "/*.lock", false, true)
end

---Install the HOME/CLAUDE_CONFIG_DIR sandbox.
---
---An externally supplied $CLAUDE_CONFIG_DIR is honoured — that is how a check
---hands a shared lock directory to a child process — but only after it is
---proven to be scratch space under the system temp root. Otherwise a fresh
---per-process directory is created.
function M.sandbox()
  if package.loaded["codriver.vendor.claudecode.lockfile"] then
    M.fail(
      "codriver.vendor.claudecode.lockfile was loaded before the sandbox was installed — its lock_dir is "
        .. "frozen at module load, so it is still pointing at the real ~/.claude/ide"
    )
  end

  local sys_tmp = resolved(vim.env.TMPDIR or "/tmp")
  local supplied = vim.env.CLAUDE_CONFIG_DIR
  local config

  if supplied and supplied ~= "" then
    config = supplied
    if not is_inside(resolved(config), sys_tmp) then
      M.fail(
        "$CLAUDE_CONFIG_DIR is %s, which is outside the temp root %s — refusing to run, because these checks "
          .. "delete lockfiles and that path may belong to a live Claude session",
        resolved(config),
        sys_tmp
      )
    end
    M.sandbox_root = config
  else
    M.sandbox_root = vim.fn.tempname()
    config = M.sandbox_root .. "/claude"
    local home = M.sandbox_root .. "/home"
    vim.fn.mkdir(home, "p", tonumber("700", 8))
    vim.fn.mkdir(config, "p", tonumber("700", 8))
    vim.env.HOME = home
    vim.env.CLAUDE_CONFIG_DIR = config
  end

  -- Mirrors get_lock_dir() in the vendored lockfile module.
  M.lock_dir = vim.fn.expand(config .. "/ide")

  local root = resolved(M.sandbox_root)
  if not is_inside(resolved(M.lock_dir), root) then
    M.fail("lock dir %s resolves outside the sandbox %s — refusing to run", resolved(M.lock_dir), root)
  end

  local existing = M.lock_files()
  if #existing > 0 then
    M.fail("lock dir %s is not empty before anything started: %s", M.lock_dir, table.concat(existing, ", "))
  end

  return M
end

---Put the plugin on runtimepath and install the sandbox. Idempotent.
---@return table harness
function M.setup()
  if M.sandbox_root then
    return M
  end
  vim.opt.runtimepath:prepend(M.repo_root)
  vim.opt.swapfile = false
  return M.sandbox()
end

return M
