---@brief Turning a user's `setup()` table into two configs.
---
--- Codriver keeps its own options at the top level and the vendored layer's
--- options nested under `claudecode`:
---
---   require("codriver").setup({
---     auto_start = true,                      -- codriver's
---     claudecode = { log_level = "debug" },   -- the vendored layer's
---   })
---
--- The boundary is what makes an unknown top-level key an error rather than a
--- guess, and what lets a vendor re-sync add or rename keys upstream without
--- ever colliding with codriver's own key space.
---
--- This module is pure. It touches `vim.notify`, `vim.log.levels` and
--- `vim.inspect` and nothing else, so it can be tested under bare LuaJIT
--- against the tiny stub in tests/busted_setup.lua. Reaching for anything
--- wider — `vim.tbl_deep_extend` above all — would mean either widening that
--- stub or moving these tests into headless Neovim, and both are worse than
--- twenty lines of merging.

local M = {}

---Options codriver owns. Everything else belongs to the vendored layer.
---@type table<string, true>
local CODRIVER_KEYS = {
  auto_start = true,
  claudecode = true,
  test_command = true,
  bash_allow = true,
  write_allow = true,
  keys = true,
}

---@class CodriverOptions
---@field auto_start boolean Open a session when `setup()` runs.

---Codriver's own defaults.
---
---`auto_start` is off because codriver's premise is that nothing happens
---without a human at the keyboard. Opening a WebSocket server and writing a
---lockfile on every `nvim` launch contradicts that, and litters one lockfile
---per Neovim instance. Users who want Claude always reachable opt in.
---
---`keys` are on by default — a plugin whose commands need to be typed out
---isn't "reachable via a keymap". `opts.keys.<name> = false` disables one
---without clobbering a user's own binding of the same lhs.
---@type CodriverOptions
M.defaults = {
  auto_start = false,
  keys = {
    send = "<leader>cs",
    send_text = "<leader>cS",
  },
}

---Vendored defaults codriver has an opinion about. Deliberately short: every
---other vendored key is left alone for the vendored `config.apply()` to
---default, so a re-sync that changes one of those changes it here too.
---@type table
M.claudecode_defaults = {
  -- Claude reading your buffer and your visual selection depends on this. It
  -- is upstream's default too, but pinning it here means the one place it can
  -- be switched off is a place that warns about what that costs.
  track_selection = true,
  terminal = {
    -- Upstream's auto-detection already picks snacks/native/external
    -- correctly. Overriding it would be a divergence with nothing to gain.
    provider = "auto",
  },
}

---Copy a value, following tables. Functions, userdata and the like are shared
---by reference — a terminal provider passed in as a table of callbacks has to
---come out the other side still calling the same functions.
---@generic T
---@param value T
---@param seen table|nil
---@return T
local function deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[key] = deep_copy(item, seen)
  end
  return copy
end

---Merge `override` onto a copy of `base`. Neither is mutated.
---@param base table
---@param override table|nil
---@return table
local function deep_merge(base, override)
  local out = deep_copy(base)
  for key, value in pairs(override or {}) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = deep_merge(out[key], value)
    else
      out[key] = deep_copy(value)
    end
  end
  return out
end

---@param message string
local function warn(message)
  vim.notify("codriver.config: " .. message, vim.log.levels.WARN)
end

---Validate that `value` is a table of non-empty strings, naming `field_name` in
---any error. Called one frame below `M.resolve`, so errors raise at level 3 to
---still point at `setup()`'s own call site, matching the level-2 checks that
---live directly in `M.resolve`.
---@param value any
---@param field_name string
local function validate_string_list(value, field_name)
  if type(value) ~= "table" then
    error(("codriver.config: %s must be a table, got %s"):format(field_name, vim.inspect(value)), 3)
  end
  for i, entry in ipairs(value) do
    if type(entry) ~= "string" or entry == "" then
      error(
        ("codriver.config: %s[%d] must be a non-empty string, got %s"):format(field_name, i, vim.inspect(entry)),
        3
      )
    end
  end
end

---Sorted list of the option names codriver accepts at the top level.
---@return string
local function codriver_key_list()
  local keys = {}
  for key in pairs(CODRIVER_KEYS) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return table.concat(keys, ", ")
end

---Sorted list of the keymap names codriver accepts under `opts.keys`.
---@return string
local function keys_key_list()
  local names = {}
  for name in pairs(M.defaults.keys) do
    table.insert(names, name)
  end
  table.sort(names)
  return table.concat(names, ", ")
end

---Resolve `opts.keys` against `M.defaults.keys`.
---
---An entry set to `false` disables that keymap — it is left out of the
---result entirely rather than carried forward as a falsy value, so
---keymaps.lua can just iterate whatever it is handed. `nil`/omission is not
---a distinct case: it resolves to the enabled default. Anything else must be
---a non-empty string overriding the default lhs. Called one frame below
---`M.resolve`, so errors raise at level 3 to still point at `setup()`'s own
---call site, matching `validate_string_list`.
---@param value table|nil
---@return table<string, string>
local function resolve_keys(value)
  if value == nil then
    value = {}
  end
  if type(value) ~= "table" then
    error(("codriver.config: keys must be a table, got %s"):format(vim.inspect(value)), 3)
  end

  local unknown = {}
  for name in pairs(value) do
    if M.defaults.keys[name] == nil then
      table.insert(unknown, tostring(name))
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    error(
      ("codriver.config: unknown key%s under `keys`: %s. codriver's keymaps are: %s"):format(
        #unknown > 1 and "s" or "",
        table.concat(unknown, ", "),
        keys_key_list()
      ),
      3
    )
  end

  local resolved = {}
  for name, default_lhs in pairs(M.defaults.keys) do
    local entry = value[name]
    if entry == nil then
      resolved[name] = default_lhs
    elseif entry == false then
      -- disabled: leave it out of the resolved table entirely.
    elseif type(entry) == "string" and entry ~= "" then
      resolved[name] = entry
    else
      error(
        ("codriver.config: keys.%s must be a non-empty string or false, got %s"):format(name, vim.inspect(entry)),
        3
      )
    end
  end
  return resolved
end

---Split a user's `setup()` table into codriver's config and the vendored one.
---
---Raises on an unknown top-level key rather than passing a half-understood
---table down: a typo that silently does nothing is worse than a stack trace.
---@param opts table|nil
---@return { codriver: CodriverOptions, claudecode: table }
function M.resolve(opts, channel)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    error(("codriver.config: setup() expects a table, got %s"):format(vim.inspect(opts)), 2)
  end

  local unknown = {}
  for key in pairs(opts) do
    if not CODRIVER_KEYS[key] then
      table.insert(unknown, tostring(key))
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    error(
      ("codriver.config: unknown top-level option%s: %s. codriver's options are: %s — everything else belongs to "):format(
        #unknown > 1 and "s" or "",
        table.concat(unknown, ", "),
        codriver_key_list()
      ) .. "the vendored layer and goes under `claudecode = { ... }`",
      2
    )
  end

  local auto_start = M.defaults.auto_start
  if opts.auto_start ~= nil then
    if type(opts.auto_start) ~= "boolean" then
      error(("codriver.config: auto_start must be a boolean, got %s"):format(vim.inspect(opts.auto_start)), 2)
    end
    auto_start = opts.auto_start
  end
  local test_command = nil
  if opts.test_command ~= nil then
    if type(opts.test_command) ~= "string" then
      error(("codriver.config: test_command must be a string, got %s"):format(vim.inspect(opts.test_command)), 2)
    end
    test_command = opts.test_command
  end
  if opts.claudecode ~= nil and type(opts.claudecode) ~= "table" then
    error(("codriver.config: claudecode must be a table, got %s"):format(vim.inspect(opts.claudecode)), 2)
  end
  local bash_allow = nil
  if opts.bash_allow ~= nil then
    if type(opts.bash_allow) ~= "table" then
      error(("codriver.config: bash_allow must be a table, got %s"):format(vim.inspect(opts.bash_allow)), 2)
    end
    if opts.bash_allow.heads ~= nil then
      validate_string_list(opts.bash_allow.heads, "bash_allow.heads")
    end
    if opts.bash_allow.git_subcommands ~= nil then
      validate_string_list(opts.bash_allow.git_subcommands, "bash_allow.git_subcommands")
    end
    bash_allow = deep_copy(opts.bash_allow)
  end
  local write_allow = nil
  if opts.write_allow ~= nil then
    validate_string_list(opts.write_allow, "write_allow")
    write_allow = deep_copy(opts.write_allow)
  end
  local keys = resolve_keys(opts.keys)

  local claudecode = deep_merge(M.claudecode_defaults, opts.claudecode)
  claudecode.env = claudecode.env or {}

  if channel ~= nil then
    if claudecode ~= nil then
      if claudecode.env ~= nil then
        local set = {}
        for _, key in pairs({ "CODRIVER_NVIM_ADDRESS", "CODRIVER_STATE_FILE" }) do
          if claudecode.env[key] ~= nil then
            table.insert(set, tostring(key))
          end
        end
        if #set > 0 then
          warn(("claudecode env values already set: %s"):format(table.concat(set, ", ")))
        end
      end
    end

    claudecode.env.CODRIVER_STATE_FILE = tostring(channel.state_file)
    claudecode.env.CODRIVER_NVIM_ADDRESS = tostring(channel.nvim_address)
  end

  if opts.claudecode and opts.claudecode.auto_start ~= nil then
    warn(
      "`claudecode.auto_start` is not yours to set — codriver starts the session itself. "
        .. "Use the top-level `auto_start` option to open one when Neovim launches."
    )
  end
  -- Forced, not defaulted. The vendored `setup()` starts a server and writes a
  -- lockfile when this is true, and it does it before codriver has registered a
  -- single command. Launch-time start is codriver's `auto_start` to run, from
  -- the wrapper, after everything else is in place.
  claudecode.auto_start = false

  if claudecode.track_selection == false then
    warn(
      "`claudecode.track_selection = false` turns off selection tracking — Claude will not be able to read "
        .. "your visual selection or the buffer you are working in."
    )
  end

  return {
    codriver = {
      auto_start = auto_start,
      test_command = test_command,
      bash_allow = bash_allow,
      write_allow = write_allow,
      keys = keys,
    },
    claudecode = claudecode,
  }
end

return M
