require("tests.busted_setup")

local session = require("codriver.session")

local VENDOR = "codriver.vendor.claudecode"
local TERMINAL = VENDOR .. ".terminal"
local LOCKFILE = VENDOR .. ".lockfile"
local SELECTION = VENDOR .. ".selection"
local CLAUDE_SETTINGS = "codriver.hook.claude_settings"
local HOOK_STATE = "codriver.hook.state"

local LOCK_DIR = "/tmp/codriver-session-spec/ide"
local CWD = "/tmp/codriver-session-spec/project"

---Shared ordering log. Server-before-terminal is the contract, not just the
---call counts, so both fakes record into one list.
local events

---A stand-in for the vendored claudecode module, shaped like the real one:
---`state.server` is the server module, `start`/`stop` return
---`(ok, port_or_error)`, and selection is armed *inside* start, gated on the
---config — which is what makes wrapper-side arming detectable.
local function fake_vendor()
  local fake = {
    state = { server = nil, port = nil, config = {} },
    calls = { start = 0, stop = 0, start_args = {} },
    selection_armed = false,
    status = { running = true, port = 12345, client_count = 0, clients = {} },
  }

  fake.server_module = {
    get_status = function()
      return fake.status
    end,
  }

  fake.setup = function(config)
    fake.state.config = config or {}
  end

  fake.start = function(show_notification)
    fake.calls.start = fake.calls.start + 1
    table.insert(fake.calls.start_args, show_notification)
    table.insert(events, "vendor.start")

    if fake.start_error then
      return false, fake.start_error
    end
    if fake.state.server then
      return false, "Already running"
    end

    fake.state.server = fake.server_module
    fake.state.port = fake.status.port
    if fake.state.config.track_selection then
      fake.selection_armed = true
    end
    return true, fake.state.port
  end

  fake.stop = function()
    fake.calls.stop = fake.calls.stop + 1
    table.insert(events, "vendor.stop")

    if not fake.state.server then
      return false, "Not running"
    end
    if fake.stop_error then
      return false, fake.stop_error
    end

    if fake.state.config.track_selection then
      fake.selection_armed = false
    end
    fake.state.server = nil
    fake.state.port = nil
    return true
  end

  return fake
end

local function fake_terminal()
  local fake = { opened = 0, open_args = {} }
  fake.open = function(opts)
    fake.opened = fake.opened + 1
    table.insert(fake.open_args, opts)
    table.insert(events, "terminal.open")
  end
  return fake
end

local function fake_selection()
  local fake = { enabled = 0, disabled = 0 }
  fake.enable = function()
    fake.enabled = fake.enabled + 1
  end
  fake.disable = function()
    fake.disabled = fake.disabled + 1
  end
  return fake
end

---Records every registration ensure_server() asks for, in order, into the
---shared `events` log — arming is a preflight, and open-then-write is exactly
---as much a bug as write-after-open.
local function fake_claude_settings()
  local fake = { installs = {} }
  fake.install = function(path, command)
    table.insert(fake.installs, { path = path, command = command })
    table.insert(events, "claude_settings.install")
  end
  return fake
end

local function fake_hook_state()
  local fake = { cleared = 0 }
  fake.clear = function()
    fake.cleared = fake.cleared + 1
  end
  return fake
end

describe("codriver.session", function()
  local vendor, terminal, selection, claude_settings, hook_state, saved, readable

  before_each(function()
    session._reset()
    events = {}
    readable = {}
    vendor, terminal, selection = fake_vendor(), fake_terminal(), fake_selection()
    claude_settings, hook_state = fake_claude_settings(), fake_hook_state()

    saved = {}
    for _, name in ipairs({ VENDOR, TERMINAL, LOCKFILE, SELECTION, CLAUDE_SETTINGS, HOOK_STATE }) do
      saved[name] = package.loaded[name]
    end
    package.loaded[VENDOR] = vendor
    package.loaded[TERMINAL] = terminal
    package.loaded[LOCKFILE] = { lock_dir = LOCK_DIR }
    package.loaded[SELECTION] = selection
    package.loaded[CLAUDE_SETTINGS] = claude_settings
    package.loaded[HOOK_STATE] = hook_state

    -- Spec-local, not a growth of tests/busted_setup.lua's shared stub:
    -- snapshot() asks the filesystem one question and this answers it;
    -- arm() asks for the cwd and resolves its own module path to build the
    -- registered command. fnamemodify only ever needs to strip one path
    -- segment per "h" in the modifier string here, so that is all it does.
    _G.vim.fn = {
      filereadable = function(path)
        return readable[path] and 1 or 0
      end,
      getcwd = function()
        return CWD
      end,
      resolve = function(path)
        return path
      end,
      fnamemodify = function(path, mods)
        local result = path
        for _ in mods:gmatch("h") do
          result = result:match("^(.*)/[^/]+$") or result
        end
        return result
      end,
    }
  end)

  after_each(function()
    for name, module in pairs(saved) do
      package.loaded[name] = module
    end
    _G.vim.fn = nil
    _G.reset_vim_stub()
  end)

  describe("ensure_server", function()
    it("starts the server exactly once and never opens a terminal", function()
      -- This is what the terminal-opening commands call as a pre-flight. A
      -- terminal opened here means :Codriver from cold opens one, and then the
      -- vendored toggle handler hides or duplicates it.
      local result = session.ensure_server()

      assert.is_true(result.started)
      assert.are.equal(1, vendor.calls.start)
      assert.are.equal(0, terminal.opened)
      assert.are.equal(12345, result.port)
    end)

    it("suppresses the vendored startup notification", function()
      session.ensure_server()

      assert.is_false(vendor.calls.start_args[1], "the command layer reports this in codriver's own words")
    end)

    it("reports an existing session without calling the vendored start", function()
      session.ensure_server()

      local again = session.ensure_server()

      assert.is_true(again.already_running)
      assert.is_false(again.started)
      assert.are.equal(12345, again.port)
      assert.is_nil(again.error, "asking for a session you already have is not a failure")
      assert.are.equal(1, vendor.calls.start, "the vendored `false, Already running` path must not be entered")
    end)
  end)

  describe("arming", function()
    it("registers the hook before the vendored server ever starts", function()
      session.ensure_server()

      assert.are.same({ "claude_settings.install", "vendor.start" }, events)
    end)

    it("registers against the current working directory", function()
      session.ensure_server()

      assert.are.equal(1, #claude_settings.installs)
      assert.are.equal(CWD .. "/.claude/settings.local.json", claude_settings.installs[1].path)
      assert.is_truthy(
        claude_settings.installs[1].command:match("^nvim %-%-clean %-l .*/scripts/codriver%-hook%.lua$"),
        "expected the registered command to run scripts/codriver-hook.lua under --clean, got "
          .. tostring(claude_settings.installs[1].command)
      )
    end)

    it("re-registers on every ensure_server(), including when already running", function()
      -- The already_running branch returns early — arming has to happen before
      -- that, or deleting settings.local.json and calling ensure_server() again
      -- leaves the hook unregistered with nothing to say so.
      session.ensure_server()
      session.ensure_server()

      assert.are.equal(2, #claude_settings.installs)
    end)

    for _, key in ipairs({ "cwd", "cwd_provider", "git_repo_cwd" }) do
      it("warns when a non-default terminal " .. key .. " is configured", function()
        vendor.state.config = { terminal = { [key] = "/somewhere/else" } }

        session.ensure_server()

        assert.are.equal(1, #_G.vim._notifications, "expected exactly one warning")
        assert.are.equal(_G.vim.log.levels.WARN, _G.vim._notifications[1].level)
        assert.is_truthy(_G.vim._notifications[1].msg:lower():find("cwd", 1, true))
      end)
    end

    it("warns at most once per session, not once per ensure_server() call", function()
      vendor.state.config = { terminal = { cwd = "/somewhere/else" } }

      session.ensure_server()
      session.ensure_server()

      assert.are.equal(1, #_G.vim._notifications, "a warning is not a chatter loop")
    end)

    it("stays silent under the default configuration", function()
      session.ensure_server()

      assert.are.equal(0, #_G.vim._notifications)
    end)
  end)

  describe("start", function()
    it("brings the server up before opening the terminal", function()
      -- The vendored terminal builds the CLI's environment when it opens, and
      -- with no server listening there is no port to put in it. Terminal-first
      -- launches a Claude that can never connect back — and arming has to be
      -- earlier still, or the CLI could issue tool calls before the hook that
      -- governs it exists.
      local result = session.start()

      assert.is_true(result.started)
      assert.are.same({ "claude_settings.install", "vendor.start", "terminal.open" }, events)
      assert.are.equal(1, terminal.opened)
    end)

    it("still opens a terminal when the session is already live", function()
      session.start()
      events = {}

      local again = session.start()

      assert.is_true(again.already_running)
      assert.are.same(
        { "claude_settings.install", "terminal.open" },
        events,
        ":CodriverStart is also a request for somewhere to talk, and ensure_server() re-arms on the way there"
      )
    end)

    it("opens no terminal when the server could not bind", function()
      vendor.start_error = "port unavailable"

      local result = session.start()

      assert.is_false(result.started)
      assert.are.equal("port unavailable", result.error)
      assert.are.equal(0, terminal.opened, "no Claude terminal without a server behind it")
    end)

    it("reports a terminal failure without failing the session", function()
      terminal.open = function()
        error("no terminal provider")
      end

      local result = session.start()

      assert.is_true(result.started, "the server is up; the user just has nowhere to type")
      assert.is_truthy(result.terminal_error)
    end)
  end)

  describe("selection tracking", function()
    it("never arms selection itself", function()
      -- The vendored start/stop pair both gate selection on track_selection.
      -- Arming it here would make that opt-out inert and leave
      -- ClaudeCodeSelection autocmds behind after :CodriverStop.
      vendor.setup({ track_selection = true })

      session.start()

      assert.are.equal(0, selection.enabled, "the wrapper must leave arming to the vendored start")
      assert.is_true(vendor.selection_armed, "...which must still have armed it")
    end)

    it("lets the resolved config decide, both ways", function()
      vendor.setup({ track_selection = false })

      session.start()

      assert.is_false(vendor.selection_armed, "track_selection = false is a real opt-out")
      assert.are.equal(0, selection.enabled)
    end)

    it("leaves nothing armed after stop", function()
      vendor.setup({ track_selection = true })
      session.start()

      session.stop()

      assert.is_false(vendor.selection_armed)
      assert.are.equal(0, selection.disabled, "the vendored stop clears it, not the wrapper")
    end)
  end)

  describe("stop", function()
    it("returns the port it tore down", function()
      session.start()

      local result = session.stop()

      assert.is_true(result.stopped)
      assert.are.equal(12345, result.port)
      assert.is_nil(vendor.state.server)
    end)

    it("is a no-op when nothing is running", function()
      local result = session.stop()

      assert.is_true(result.already_stopped)
      assert.is_false(result.stopped)
      assert.are.equal(0, vendor.calls.stop, "the vendored `false, Not running` path must not be entered")
    end)

    it("disarms by clearing the state file", function()
      -- The settings registration deliberately survives (settings_delivery) —
      -- it is the state file that has to go, or no_session_behaviour never
      -- takes effect and a plain `claude` here stays refused with no Neovim
      -- behind it.
      session.start()

      session.stop()

      assert.are.equal(1, hook_state.cleared)
    end)

    it("does not disarm when there was nothing to stop", function()
      session.stop()

      assert.are.equal(0, hook_state.cleared)
    end)

    it("succeeds even when the lockfile has already gone", function()
      session.start()
      readable[LOCK_DIR .. "/12345.lock"] = false

      local result = session.stop()

      assert.is_true(result.stopped, "a session torn down is torn down, whoever removed the file")
    end)

    it("surfaces a vendored stop failure", function()
      session.start()
      vendor.stop_error = "server would not close"

      local result = session.stop()

      assert.is_false(result.stopped)
      assert.are.equal("server would not close", result.error)
    end)

    it("lets a fresh start follow a stop", function()
      session.start()
      session.stop()

      local again = session.start()

      assert.is_true(again.started)
      assert.are.equal(12345, again.port)
    end)
  end)

  describe("snapshot", function()
    it("reports nothing listening before a start", function()
      local snapshot = session.snapshot()

      assert.is_false(snapshot.listening)
      assert.is_false(snapshot.connected)
    end)

    it("never reads a bare client count as Claude", function()
      -- The vendored is_claude_connected() falls back to client_count > 0 when
      -- `clients` is empty, so an un-upgraded TCP connection reports as
      -- connected. This is the one path no other task leaves unstubbed.
      session.start()
      vendor.status.client_count = 1
      vendor.status.clients = {}

      local snapshot = session.snapshot()

      assert.is_true(snapshot.listening)
      assert.is_false(snapshot.connected, "a TCP client that has not upgraded is not Claude")
      assert.are.equal(1, snapshot.client_count)
    end)

    it("reports connected once a client has completed the handshake", function()
      session.start()
      vendor.status.client_count = 1
      vendor.status.clients = { { handshake_complete = true } }

      assert.is_true(session.snapshot().connected)
    end)

    it("does not accept a client that only claims to be connected", function()
      session.start()
      vendor.status.clients = { { state = "connected", handshake_complete = false } }

      assert.is_false(session.snapshot().connected)
    end)

    it("names where the lockfile is, and whether it is there", function()
      session.start()
      local path = LOCK_DIR .. "/12345.lock"
      readable[path] = true

      local snapshot = session.snapshot()

      assert.are.equal(path, snapshot.lockfile)
      assert.are.equal(path, snapshot.lockfile_path)
    end)

    it("reports a listening server whose lockfile has been unlinked", function()
      session.start()

      local snapshot = session.snapshot()

      assert.is_true(snapshot.listening)
      assert.is_nil(snapshot.lockfile, "the file is not there")
      assert.are.equal(LOCK_DIR .. "/12345.lock", snapshot.lockfile_path, "...and this is where it should have been")
    end)

    it("feeds status.describe without a key mismatch", function()
      local status = require("codriver.status")
      session.start()
      vendor.status.clients = { { handshake_complete = true } }
      readable[LOCK_DIR .. "/12345.lock"] = true

      local line = status.describe(session.snapshot())

      assert.is_truthy(line:find("12345", 1, true))
      assert.is_truthy(line:find("Claude attached", 1, true))
      assert.is_nil(line:find("lockfile missing", 1, true))
    end)
  end)
end)
