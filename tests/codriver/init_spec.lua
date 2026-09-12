require("tests.busted_setup")

local codriver = require("codriver")

local VENDOR = "codriver.vendor.claudecode"
local TERMINAL = VENDOR .. ".terminal"
local LOCKFILE = VENDOR .. ".lockfile"

local LOCK_DIR = "/tmp/codriver-init-spec/ide"

---Every vendored command, as of the pinned SHA in VENDOR.md, with the flags
---that are load-bearing. Spelled out so an upstream re-sync that adds or
---renames one fails here rather than silently shrinking the surface.
local VENDORED = {
  { name = "ClaudeCodeStart", opts = { desc = "Start Claude Code integration" } },
  { name = "ClaudeCodeStop", opts = { desc = "Stop Claude Code integration" } },
  { name = "ClaudeCodeStatus", opts = { desc = "Show Claude Code integration status" } },
  { name = "ClaudeCodeSend", opts = { range = true, desc = "send" } },
  { name = "ClaudeCodeTreeAdd", opts = { desc = "tree add" } },
  { name = "ClaudeCodeAdd", opts = { nargs = "+", complete = "file", desc = "add" } },
  { name = "ClaudeCode", opts = { nargs = "*", desc = "toggle" }, terminal = "simple_toggle" },
  { name = "ClaudeCodeFocus", opts = { nargs = "*", desc = "focus" }, terminal = "focus_toggle" },
  { name = "ClaudeCodeOpen", opts = { nargs = "*", desc = "open" }, terminal = "open" },
  { name = "ClaudeCodeClose", opts = { desc = "close" }, terminal = "close" },
  { name = "ClaudeCodeSendText", opts = { nargs = "+", bang = true, desc = "text" }, terminal = "send_to_terminal" },
  { name = "ClaudeCodeDiffAccept", opts = { desc = "accept" } },
  { name = "ClaudeCodeDiffDeny", opts = { desc = "deny" } },
  { name = "ClaudeCodeCloseAllDiffs", opts = { desc = "close diffs" } },
  { name = "ClaudeCodeSelectModel", opts = { nargs = "*", desc = "model" }, terminal = "open" },
}

---Shared ordering log: server-before-terminal is the contract, not just the
---call counts.
local events

---A stand-in for `vim.api`, recording what actually reached it.
local function fake_api()
  local api = { created = {}, augroups = {}, autocmds = {}, highlights = {} }

  api.nvim_create_user_command = function(name, handler, opts)
    table.insert(api.created, { name = name, handler = handler, opts = opts })
  end

  api.nvim_create_augroup = function(name, opts)
    table.insert(api.augroups, { name = name, opts = opts })
    return #api.augroups
  end

  api.nvim_create_autocmd = function(event, opts)
    table.insert(api.autocmds, { event = event, opts = opts })
  end

  -- t-2's addition: codriver.winbar registers its highlight groups on every
  -- setup(). These tests don't care how the groups are styled, only that
  -- setup() completes, so this just records the call.
  api.nvim_set_hl = function(ns, name, attrs)
    api.highlights[name] = attrs
  end

  return api
end

---The vendored terminal module in miniature. Every entry point that puts a
---window on screen bumps one counter, because "exactly one terminal" is the
---assertion, not "exactly one call to `open`".
local function fake_terminal()
  local fake = { opened = 0, calls = {} }

  for _, name in ipairs({ "open", "simple_toggle", "focus_toggle" }) do
    fake[name] = function()
      fake.opened = fake.opened + 1
      table.insert(fake.calls, name)
      table.insert(events, "terminal." .. name)
    end
  end

  fake.close = function()
    table.insert(fake.calls, "close")
  end
  fake.send_to_terminal = function()
    table.insert(fake.calls, "send_to_terminal")
  end

  return fake
end

---A stand-in for the vendored claudecode module: `setup()` registers the same
---fifteen commands the real `_create_commands()` does (and creates the same
---shutdown augroup), `start`/`stop` return `(ok, port_or_error)`.
local function fake_vendor(terminal)
  local fake = {
    state = { server = nil, port = nil, config = {} },
    calls = { setup = 0, start = 0, stop = 0 },
    status = { running = true, port = 12345, client_count = 0, clients = {} },
    ---Names to register on top of the fifteen — an upstream re-sync, simulated.
    extra_commands = {},
  }

  fake.server_module = {
    get_status = function()
      return fake.status
    end,
  }

  fake.start = function(show_notification)
    fake.calls.start = fake.calls.start + 1
    fake.last_start_arg = show_notification
    table.insert(events, "vendor.start")

    if fake.start_error then
      return false, fake.start_error
    end
    if fake.state.server then
      return false, "Already running"
    end

    fake.state.server = fake.server_module
    fake.state.port = fake.status.port
    return true, fake.state.port
  end

  fake.stop = function()
    fake.calls.stop = fake.calls.stop + 1
    if not fake.state.server then
      return false, "Not running"
    end
    fake.state.server = nil
    fake.state.port = nil
    return true
  end

  fake.setup = function(config)
    fake.calls.setup = fake.calls.setup + 1
    fake.state.config = config or {}

    if config and config.auto_start then
      fake.start(false)
    end

    for _, command in ipairs(VENDORED) do
      vim.api.nvim_create_user_command(command.name, function(args)
        table.insert(fake.invoked, { name = command.name, args = args })
        if command.terminal then
          terminal[command.terminal]()
        end
      end, command.opts)
    end

    for _, name in ipairs(fake.extra_commands) do
      vim.api.nvim_create_user_command(name, function() end, {})
    end

    vim.api.nvim_create_augroup("ClaudeCodeShutdown", { clear = true })
  end

  fake.invoked = {}

  return fake
end

---The `:Codriver*` names currently registered, deduplicated the way Neovim
---does it — a second `nvim_create_user_command` for a name replaces the first.
local function registered_names(api)
  local names = {}
  for _, entry in ipairs(api.created) do
    names[entry.name] = true
  end
  return names
end

---@return function|nil
local function handler_for(api, name)
  local found
  for _, entry in ipairs(api.created) do
    if entry.name == name then
      found = entry
    end
  end
  return found and found.handler or nil
end

---@return table|nil
local function entry_for(api, name)
  local found
  for _, entry in ipairs(api.created) do
    if entry.name == name then
      found = entry
    end
  end
  return found
end

---The last thing notified, as text.
local function last_notification()
  local notifications = _G.vim._notifications
  local last = notifications[#notifications]
  return last and last.msg or nil
end

describe("codriver", function()
  describe("version", function()
    it("is semver-shaped and says so itself", function()
      assert.is_number(codriver.version.major)
      assert.is_number(codriver.version.minor)
      assert.is_number(codriver.version.patch)

      -- Derived, never a literal: pinning the string here would redden this
      -- spec on the next phase bump for a reason unrelated to its work.
      assert.are.equal(
        ("%d.%d.%d"):format(codriver.version.major, codriver.version.minor, codriver.version.patch),
        codriver.version:string()
      )
    end)

    it("tracks the dross phase version", function()
      local file = assert(io.open(".dross/state.json", "r"), "run busted from the repo root")
      local content = file:read("*a")
      file:close()

      local recorded = assert(content:match('"version"%s*:%s*"([^"]+)"'), "no version in .dross/state.json")
      local major, minor, patch = recorded:match("^(%d+)%.(%d+)%.(%d+)%.")

      assert.are.equal(("%s.%s.%s"):format(major, minor, patch), codriver.version:string())
    end)
  end)

  describe("module surface", function()
    it("exposes setup", function()
      assert.is_function(codriver.setup)
    end)

    it("re-exports role state off the top-level module", function()
      assert.are.equal(require("codriver.role"), codriver.role)
      assert.are.equal("navigator", codriver.role.get())
    end)
  end)

  describe("setup", function()
    local vendor, terminal, saved, readable

    before_each(function()
      events = {}
      readable = {}
      terminal = fake_terminal()
      vendor = fake_vendor(terminal)

      saved = {}
      for _, name in ipairs({ VENDOR, TERMINAL, LOCKFILE }) do
        saved[name] = package.loaded[name]
      end
      package.loaded[VENDOR] = vendor
      package.loaded[TERMINAL] = terminal
      package.loaded[LOCKFILE] = { lock_dir = LOCK_DIR }

      _G.vim.api = fake_api()
      _G.vim.fn = {
        filereadable = function(path)
          return readable[path] and 1 or 0
        end,
        -- The rest are t-8's addition: codriver.hook.state and the RPC-address
        -- guard now run on every setup(), so this fake has to answer for them
        -- too — busted has no real filesystem or server behind these, and none
        -- of these tests care about their content, only that setup() completes.
        stdpath = function()
          return "/tmp/codriver-init-spec/state"
        end,
        -- t-9's addition: ensure_server() now arms codriver's PreToolUse hook
        -- against the cwd on every preflight, so this too has to answer rather
        -- than error — these tests care about the terminal/server ordering,
        -- not about where the hook gets registered.
        getcwd = function()
          return "/tmp/codriver-init-spec/project"
        end,
        resolve = function(path)
          return path
        end,
        fnamemodify = function(path, mods)
          local result = path
          for _ in mods:gmatch("h") do
            result = result:match("^(.*)/[^/]+$") or "."
          end
          return result
        end,
        mkdir = function()
          return 1
        end,
        writefile = function()
          return 0
        end,
        -- session.stop() (t-9) clears the state file via hook.state.clear().
        delete = function()
          return 0
        end,
        serverstart = function()
          return "/tmp/codriver-init-spec.pipe"
        end,
      }
      -- claude_settings.install() (also t-9's addition, via arm()) splits its
      -- encoded document before handing it to the writefile stub above, which
      -- ignores its argument entirely — so this only has to not error.
      _G.vim.split = function(s)
        return { s }
      end
      _G.vim.uv = {
        os_getpid = function()
          return 4242
        end,
        fs_rename = function()
          return true
        end,
      }
      _G.vim.json = {
        encode = function()
          return "{}"
        end,
      }
      _G.vim.v = { servername = "" }
      -- t-2's addition: codriver.winbar paints into vim.o.winbar on every
      -- setup(). A plain table stands in for the real global-local option.
      _G.vim.o = { winbar = "" }
      -- shorten-send-commands' addition: codriver.keymaps.apply() now runs on
      -- every setup(), which reaches for vim.keymap.set. These tests care
      -- about setup()'s command/terminal/server orchestration, not about
      -- which keys get bound, so a no-op stands in.
      _G.vim.keymap = { set = function() end }
    end)

    after_each(function()
      -- Restored by iterating the *names*, not `pairs(saved)`: a module that
      -- was absent has no key, so pairs() would leave the fake in place and
      -- make every later file order-dependent.
      for _, name in ipairs({ VENDOR, TERMINAL, LOCKFILE }) do
        package.loaded[name] = saved[name]
      end
      _G.vim.api = nil
      _G.vim.fn = nil
      _G.vim.uv = nil
      _G.vim.json = nil
      _G.vim.v = nil
      _G.vim.split = nil
      _G.vim.o = nil
      _G.vim.keymap = nil
      _G.reset_vim_stub()
    end)

    describe("command surface", function()
      it("registers only :Codriver* names", function()
        codriver.setup({})

        assert.is_true(#_G.vim.api.created > 0)
        for _, entry in ipairs(_G.vim.api.created) do
          assert.is_truthy(entry.name:match("^Codriver"), entry.name .. " is not a :Codriver* name")
          assert.is_nil(entry.name:match("^ClaudeCode"), entry.name .. " leaked the vendored namespace")
        end
      end)

      it("re-exports every vendored command", function()
        codriver.setup({})

        local names = registered_names(_G.vim.api)
        local commands = require("codriver.commands")
        for _, command in ipairs(VENDORED) do
          local target = commands.map[command.name]
          assert.is_truthy(target, command.name .. " has no :Codriver* name")
          assert.is_true(names[target] == true, target .. " was not registered")
        end
      end)

      it("refuses a vendored command the rename map has never heard of", function()
        -- The upstream-re-sync tripwire: a new command must be answered in
        -- codriver.commands.map, not quietly dropped.
        vendor.extra_commands = { "ClaudeCodeNewThing" }

        local ok, err = pcall(codriver.setup, {})

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("ClaudeCodeNewThing", 1, true))
      end)

      it("keeps the vendored option flags on the re-exported commands", function()
        codriver.setup({})

        assert.is_true(entry_for(_G.vim.api, "CodriverSend").opts.range)
        assert.are.equal("+", entry_for(_G.vim.api, "CodriverAdd").opts.nargs)
        assert.are.equal("file", entry_for(_G.vim.api, "CodriverAdd").opts.complete)
        assert.is_true(entry_for(_G.vim.api, "CodriverSendText").opts.bang)
      end)

      it("renames the vendored shutdown augroup", function()
        codriver.setup({})

        assert.are.equal("CodriverShutdown", _G.vim.api.augroups[1].name)
      end)

      it("survives being set up twice", function()
        codriver.setup({})
        local first = registered_names(_G.vim.api)

        assert.has_no.errors(function()
          codriver.setup({})
        end)

        local second = registered_names(_G.vim.api)
        for name in pairs(first) do
          assert.is_true(second[name] == true, name .. " went missing on the second setup")
        end
        for name in pairs(second) do
          assert.is_nil(name:match("^ClaudeCode"), name .. " leaked on the second setup")
        end
      end)
    end)

    describe("auto-start", function()
      it("opens nothing by default", function()
        codriver.setup({})

        assert.are.equal(0, vendor.calls.start, "nothing happens without a human at the keyboard")
        assert.is_nil(vendor.state.server)
        assert.are.equal(0, terminal.opened)
      end)

      it("opens a session when asked to", function()
        codriver.setup({ auto_start = true })

        assert.are.equal(1, vendor.calls.start)
        assert.are.equal(12345, vendor.state.port)
      end)

      it("never lets the vendored setup start the server itself", function()
        -- config.resolve forces `claudecode.auto_start` off. If it ever leaked
        -- through, the vendored start would run *inside* the capture shim.
        codriver.setup({ auto_start = true })

        assert.is_false(vendor.state.config.auto_start)
        assert.are.same({ "vendor.start", "terminal.open" }, events, "the wrapper starts the session, after setup")
      end)

      it("reports the port it opened", function()
        codriver.setup({ auto_start = true })

        assert.is_truthy(last_notification():find("12345", 1, true))
      end)
    end)

    describe("pre-flight guard", function()
      local function invoke(name)
        local handler = assert(handler_for(_G.vim.api, name), name .. " is not registered")
        handler({ args = "" })
      end

      it("brings the server up before a terminal command runs", function()
        for _, name in ipairs({ "Codriver", "CodriverOpen", "CodriverFocus", "CodriverSelectModel" }) do
          codriver.setup({})
          events = {}

          invoke(name)

          -- The vendored env builder omits CLAUDE_CODE_SSE_PORT when the server
          -- is down, so a terminal opened first runs a Claude that can never
          -- connect back. Order is the contract, not just the call counts.
          assert.are.equal("vendor.start", events[1], name .. " opened a terminal before the server")
          assert.is_truthy(events[2]:match("^terminal%."), name .. " never reached the vendored handler")

          vendor.stop()
        end
      end)

      it("leaves the terminal to the vendored handler", function()
        codriver.setup({})

        invoke("Codriver")

        -- ensure_server(), not start(): a wrapper that opened a terminal too
        -- would leave :Codriver from cold showing two.
        assert.are.equal(1, terminal.opened, "the guard must be server-only")
        assert.are.same({ "simple_toggle" }, terminal.calls)
      end)

      it("does not re-enter a live session", function()
        codriver.setup({ auto_start = true })
        events = {}

        invoke("CodriverOpen")

        assert.are.equal(1, vendor.calls.start, "the guard must not restart a session it already has")
        assert.are.same({ "terminal.open" }, events)
      end)

      it("opens no terminal when the server could not bind", function()
        codriver.setup({})
        vendor.start_error = "port unavailable"

        invoke("Codriver")

        assert.are.equal(0, terminal.opened, "no Claude terminal without a server behind it")
        assert.is_truthy(last_notification():find("port unavailable", 1, true))
      end)

      it("leaves the non-terminal commands unwrapped", function()
        codriver.setup({})

        handler_for(_G.vim.api, "CodriverDiffAccept")({ args = "" })

        assert.are.equal(0, vendor.calls.start, "a diff command has no business starting a server")
        assert.are.equal("ClaudeCodeDiffAccept", vendor.invoked[1].name)
      end)
    end)

    describe("session commands", function()
      it("answers :CodriverStart itself", function()
        codriver.setup({})

        handler_for(_G.vim.api, "CodriverStart")({})

        assert.are.equal(1, vendor.calls.start)
        assert.is_truthy(last_notification():find("12345", 1, true))
      end)

      it("reports a second start as the session it already has", function()
        codriver.setup({})
        handler_for(_G.vim.api, "CodriverStart")({})

        handler_for(_G.vim.api, "CodriverStart")({})

        local message = last_notification()
        assert.is_truthy(message:find("already running", 1, true))
        assert.is_truthy(message:find("12345", 1, true))
      end)

      it("answers :CodriverStop itself", function()
        codriver.setup({})
        handler_for(_G.vim.api, "CodriverStart")({})

        handler_for(_G.vim.api, "CodriverStop")({})

        assert.is_nil(vendor.state.server)
        assert.is_truthy(last_notification():find("12345", 1, true))
      end)

      it("does not raise when there is nothing to stop", function()
        codriver.setup({})

        handler_for(_G.vim.api, "CodriverStop")({})

        assert.are.equal(0, vendor.calls.stop, "the vendored `false, Not running` path must not be entered")
        assert.is_truthy(last_notification():find("no session", 1, true))
      end)

      it("distinguishes listening from connected through :CodriverStatus", function()
        -- The keys session.snapshot() produces and the keys status.describe()
        -- consumes are the same keys, or this line says the wrong thing.
        codriver.setup({})
        handler_for(_G.vim.api, "CodriverStart")({})
        readable[LOCK_DIR .. "/12345.lock"] = true

        handler_for(_G.vim.api, "CodriverStatus")({})
        assert.is_truthy(last_notification():find("waiting for Claude", 1, true))

        vendor.status.client_count = 1
        vendor.status.clients = { { handshake_complete = true } }

        handler_for(_G.vim.api, "CodriverStatus")({})
        local message = last_notification()
        assert.is_truthy(message:find("Claude attached", 1, true))
        assert.is_nil(message:find("waiting for Claude", 1, true))
      end)

      it("reports no session before anything is started", function()
        codriver.setup({})

        handler_for(_G.vim.api, "CodriverStatus")({})

        assert.is_truthy(last_notification():find("no session", 1, true))
        assert.is_nil(vendor.state.server, "a status query must have no side effects")
      end)
    end)

    describe("handover commands", function()
      before_each(function()
        codriver.role._reset()
      end)

      it("hands the keyboard to Claude", function()
        codriver.setup({})

        handler_for(_G.vim.api, "CodriverHandover")({})

        assert.are.equal("driver", codriver.role.get())
      end)

      it("takes the keyboard back", function()
        codriver.setup({})
        handler_for(_G.vim.api, "CodriverHandover")({})

        handler_for(_G.vim.api, "CodriverTakeback")({})

        assert.are.equal("navigator", codriver.role.get())
      end)

      it("notifies on handover", function()
        codriver.setup({})

        handler_for(_G.vim.api, "CodriverHandover")({})

        assert.is_truthy(last_notification():find("driving", 1, true))
      end)

      it("notifies on takeback", function()
        codriver.setup({})
        handler_for(_G.vim.api, "CodriverHandover")({})

        handler_for(_G.vim.api, "CodriverTakeback")({})

        assert.is_truthy(last_notification():find("you're driving", 1, true))
      end)

      it("survives being set up twice", function()
        codriver.setup({})

        assert.has_no.errors(function()
          codriver.setup({})
        end)

        handler_for(_G.vim.api, "CodriverHandover")({})
        assert.are.equal("driver", codriver.role.get())
      end)
    end)

    describe("reload", function()
      before_each(function()
        codriver.role._reset()
      end)

      it("restores a live role after setup() re-runs post hot-reload", function()
        codriver.setup({})

        -- Simulate a plugin hot-reload: the Lua module's in-memory role resets
        -- to the default even though this pid's on-disk record still says a
        -- driver session was live.
        codriver.role._reset()
        readable[require("codriver.hook.state").path()] = true
        _G.vim.fn.readfile = function()
          return { "{}" }
        end
        _G.vim.json.decode = function()
          return { role = "driver" }
        end

        codriver.setup({})

        assert.are.equal("driver", codriver.role.get())
      end)

      it("does not restore when this pid has no live record", function()
        codriver.setup({})

        assert.are.equal("navigator", codriver.role.get())
      end)
    end)
  end)

  describe("laziness", function()
    it("does not load the vendored protocol layer just by being required", function()
      -- Requiring codriver must stay cheap and side-effect free: the WebSocket
      -- server and lockfile machinery should only wake up on setup(). This also
      -- catches a fake-vendor test above failing to put package.loaded back.
      assert.is_nil(package.loaded[VENDOR])
    end)
  end)
end)
