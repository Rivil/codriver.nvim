# session-bringup — verification lens

Every criterion was first written as a test contract, then reduced to the smallest task
that makes that contract assertable. Two harnesses exist and neither is optional:

- **busted** (`mise run test` → `./.luarocks/bin/busted`) — bare LuaJIT, no Neovim. Only the
  tiny stub in `tests/busted_setup.lua` is available. Anything testable here is testable
  cheaply and deterministically, so the wrapper is deliberately shaped to keep session
  state, option resolution, command mapping and status wording in pure modules.
- **headless nvim** (`mise run test-nvim`) — real `vim`, real WebSocket server, real
  lockfile, real user commands. Today this task runs exactly one hardcoded script
  (`nvim --clean --headless -l tests/nvim/vendor_smoke.lua`), so **any new headless spec is
  dead code until the runner iterates the directory**. That is why t-1 is wave 1.

```
Phase session-bringup — 12 tasks across 4 waves

Wave 1
  t-1  Add headless spec runner and harness
       files:    tests/nvim/harness.lua, tests/nvim/harness_selfcheck_spec.lua,
                 mise.toml, tests/busted_setup.lua
       covers:   (enabler — no criterion; unlocks the headless contracts of c-1..c-8)
       contract: harness_selfcheck_spec asserts CLAUDE_CONFIG_DIR resolves inside a
                 per-run temp dir (never ~/.claude/ide) and that the lock dir is empty
                 before any start — if the harness stops isolating it, the spec fails and
                 the suite can no longer write lockfiles into the developer's real dir.
       contract: harness_selfcheck_spec spawns a child `nvim --clean --headless -l` on a
                 script whose harness assertion fails, and asserts the child exit code is
                 non-zero — if `harness.expect` degrades to print-and-continue, every
                 downstream headless contract silently passes and this spec fails.
       contract: `mise run test-nvim` runs every `tests/nvim/*_spec.lua` plus
                 vendor_smoke.lua, each in its own nvim process, and exits non-zero on the
                 first failure — if the task keeps its single hardcoded path, adding a
                 red spec file leaves `mise run test` green, which the selfcheck's
                 "spec files discovered == files on disk" assertion catches.

  t-2  Resolve and validate codriver options
       files:    lua/codriver/config.lua, tests/codriver/config_spec.lua
       covers:   c-8
       description: Pure resolver splitting top-level codriver keys from nested
                 `claudecode = { … }`, rejecting unknown top-level keys and forcing the
                 vendored `auto_start` to false. Returns `{ codriver = …, claudecode = … }`.
       contract: `config.resolve({ auto_strt = true })` raises an error naming
                 `auto_strt` — if unknown top-level keys are forwarded instead of
                 rejected, they land in the vendored config and this assertion fails.
       contract: `config.resolve({}).claudecode.auto_start == false` **and**
                 `config.resolve({ claudecode = { auto_start = true } }).claudecode.auto_start == false`
                 — if the forcing is dropped, or a nested user value is allowed to win,
                 a server would listen at nvim launch and both assertions fail.
       contract: `config.resolve({ auto_start = true })` yields
                 `codriver.auto_start == true` with `claudecode.auto_start == false` — the
                 opt-in must never be forwarded downward; the wrapper starts the session
                 itself.
       contract: `config.resolve({ claudecode = { terminal = { provider = "snacks" } } })`
                 preserves that provider, and a bare `resolve({})` leaves the vendored
                 default `"auto"` untouched — if the wrapper starts pinning a provider,
                 this fails.
       contract: config_spec runs against the existing minimal `vim` stub with no
                 additions — if `config.lua` reaches for any `vim.*` helper, the spec
                 errors on a nil field (the resolver must stay pure Lua).

  t-3  Capture and re-export vendored commands
       files:    lua/codriver/commands.lua, tests/codriver/commands_spec.lua
       covers:   c-6, c-7
       description: `commands.capture(fn)` swaps `vim.api.nvim_create_user_command` for a
                 recorder while `fn` runs (so vendored `setup()` registers nothing), plus
                 `commands.map`, the vendored-name → `:Codriver*`-name table, and
                 `commands.register(captured)`.
       contract: a `capture()` body that calls `nvim_create_user_command` three times
                 yields three records with name/handler/opts intact and creates zero real
                 commands — if the shim forwards instead of recording, `:ClaudeCode*`
                 commands appear and c-6 breaks.
       contract: `capture()` restores the original `nvim_create_user_command` even when
                 the body raises (spec passes a throwing fn, then asserts a later create
                 call reaches the stub, not the recorder) — a leaked shim would swallow
                 every command any other plugin registers afterwards.
       contract: `commands.map` has 15 keys, one per vendored command
                 (ClaudeCode, …Focus, …Open, …Close, …Send, …Add, …TreeAdd, …SendText,
                 …DiffAccept, …DiffDeny, …CloseAllDiffs, …SelectModel, …Start, …Stop,
                 …Status), no value beginning with `ClaudeCode`, and no two keys sharing a
                 target name — if a re-export collapses two vendored handlers onto one
                 `:Codriver` name, the duplicate-target assertion fails.

  t-4  Format listening and connected status lines
       files:    lua/codriver/status.lua, tests/codriver/status_spec.lua
       covers:   c-4
       description: Pure `status.describe(snapshot)` over
                 `{ listening, port, connected, client_count, lockfile }`, producing the
                 one-line `:CodriverStatus` answer.
       contract: the three snapshots (not listening / listening+not connected /
                 listening+connected) produce three distinct strings, and the
                 not-connected line does not match the pattern the connected assertion
                 uses — if listening and connected collapse into one message, c-4's two
                 distinguishable states are gone and this fails.
       contract: `describe{ listening = true, port = 12345, … }` contains "12345" — the
                 in-flow answer must name the port without a health split.
       contract: `describe{ listening = true, connected = false, client_count = 1 }`
                 still reports *not* connected — a TCP client that never completed the
                 MCP handshake is not Claude; if `describe` starts inferring connection
                 from `client_count`, this fails.

Wave 2 (depends t-4)
  t-5  Add session start/stop/snapshot wrapper
       files:    lua/codriver/session.lua, tests/codriver/session_spec.lua
       covers:   c-1, c-2, c-5
       description: Start/stop/snapshot over the vendored module, returning structured
                 results (`{ started, already_running, port, error }`) rather than
                 printing. Reaches the vendored module only through a call-time
                 `require`, so specs can inject a fake into `package.loaded`.
       depends_on: t-4
       contract: with a fake vendor whose `state.server` is already set,
                 `session.start()` returns `already_running = true` with the same port and
                 the fake's `start` call counter stays 0 — if the wrapper delegates the
                 second start, the vendored path returns `false, "Already running"` and
                 c-1's "reports the existing session rather than erroring" is violated;
                 the counter assertion fails.
       contract: `session.start()` on a fresh fake calls `vendor.start(false)` once and
                 then the fake terminal module's `open` exactly once, in that order — if
                 the terminal is opened first, the launched CLI gets no port (see t-9).
       contract: when the fake `vendor.start` returns `false, "port unavailable"`,
                 `session.start()` returns `{ started = false, error = "port unavailable" }`
                 and `terminal.open` is never called — no Claude terminal without a
                 server behind it.
       contract: `session.stop()` with no server returns `stopped = false` and never calls
                 the fake's `stop` — and with a server, returns the port it tore down so
                 the caller can report the removed lockfile (c-5).
       contract: `status.describe(session.snapshot())` on a fake with one
                 handshake-complete client yields the connected line — this pins the
                 snapshot keys to exactly what t-4 consumes; a renamed field fails here
                 rather than silently blanking the status output.

Wave 3
  t-6  Wire setup: options, command surface, auto-start
       files:    lua/codriver/init.lua, tests/codriver/init_spec.lua
       covers:   c-6, c-7, c-8
       description: `setup(opts)` resolves options (t-2), runs the vendored `setup` inside
                 the capture shim (t-3), registers only `:Codriver*` commands — `Start`,
                 `Stop`, `Status` bound to session/status, the rest to captured vendored
                 handlers — then starts the session iff `codriver.auto_start`.
       depends_on: t-2, t-3, t-5
       contract: after `setup({})` with a fake vendor, every recorded command name matches
                 `^Codriver` and none matches `^ClaudeCode` — if the shim is bypassed or
                 registration happens outside it, this fails (and c-6 would regress to
                 stomping a real claudecode.nvim's commands).
       contract: `setup({ auto_start = true })` calls `session.start` once;
                 `setup({})` calls it zero times — the default must leave nothing
                 listening (c-8).
       contract: the existing init_spec assertion that `require("codriver")` leaves
                 `package.loaded["codriver.vendor.claudecode"]` nil must still hold —
                 wiring must not eagerly pull the protocol layer into a bare require.

  t-7  Add codriver checkhealth report
       files:    lua/codriver/health.lua
       covers:   c-4
       description: `require("codriver.health").check()` for `:checkhealth codriver` —
                 port, lockfile path, connected client count, Claude CLI and terminal
                 provider — built from `session.snapshot()`, not the vendored report.
       depends_on: t-4, t-5
       contract: (asserted headlessly in t-11) the report names `:CodriverStart` and never
                 `:ClaudeCodeStart`, and lists listening and connected as separate lines —
                 if health delegates to `codriver.vendor.claudecode.health`, its advice
                 points at a suppressed command and t-11's assertions fail.

Wave 4 (depends t-1, t-6)
  t-8  Headless session lifecycle and auto-start specs
       files:    tests/nvim/session_lifecycle_spec.lua,
                 tests/nvim/autostart_off_spec.lua, tests/nvim/autostart_on_spec.lua
       covers:   c-1, c-5, c-8
       depends_on: t-1, t-6
       description: Three scripts (auto-start needs a fresh process per scenario) driving
                 real `:CodriverStart` / `:CodriverStop` against the real server and the
                 harness's temp lock dir.
       contract: `vim.fn.execute("CodriverStart")` output contains the port reported by
                 `server.get_status().port`, and exactly one `*.lock` file exists in the
                 lock dir — if the command reports a stale or missing port, or writes no
                 lockfile, c-1/c-2's "no lockfile path by hand" breaks here.
       contract: a second `:CodriverStart` leaves `get_status().port` unchanged, still
                 exactly one lockfile, and its output matches an "already"/existing-session
                 pattern with no `E` error line — the vendored path would log a warning and
                 return `false, "Already running"`; this fails if that leaks through.
       contract: after `:CodriverStop`, `get_status().running == false` and
                 `filereadable(<lock_dir>/<port>.lock) == 0`; a following `:CodriverStart`
                 returns a fresh port and creates exactly one lockfile again — if stop
                 leaves the lockfile behind, Claude keeps discovering a dead server and
                 this fails (c-5).
       contract: `:CodriverStop` with nothing running produces a "not running" message and
                 leaves the lock dir empty, without raising.
       contract: autostart_off_spec — after `setup({})` and nothing else,
                 `get_status().running == false` and the lock dir holds zero `*.lock`
                 files; autostart_on_spec — after `setup({ auto_start = true })`,
                 `running == true` and exactly one lockfile (c-8, both halves).

  t-9  Headless Claude-terminal environment spec
       files:    tests/nvim/terminal_env_spec.lua
       covers:   c-2
       depends_on: t-1, t-6
       description: `setup({ claudecode = { terminal = { provider = <capture table> } } })`
                 with a custom table provider (setup/open/close/simple_toggle/focus_toggle/
                 get_active_bufnr/is_available), then `:CodriverStart`.
       contract: the provider's `open` is called exactly once by `:CodriverStart`, and the
                 captured env table has `CLAUDE_CODE_SSE_PORT == tostring(get_status().port)`,
                 `ENABLE_IDE_INTEGRATION == "true"`, `FORCE_CODE_TERMINAL == "true"` — if
                 the terminal is launched before the server is listening,
                 `CLAUDE_CODE_SSE_PORT` is absent (the vendored builder reads
                 `server.state.port`) and the spec fails; that absence is exactly the
                 "user sets no environment variables by hand" failure in c-2.
       contract: the captured command string's first token is `claude` (or the configured
                 `terminal_cmd`) and the spec asserts no wrapper module assigns
                 `CLAUDE_CODE_SSE_PORT` itself — the port must come from the vendored
                 launcher, not a second source that can drift.
       contract: the captured `no_proxy`/`NO_PROXY` entries include `127.0.0.1` — proves
                 the wrapper still routes through the vendored env builder rather than
                 hand-rolling an env table.

  t-10 Headless buffer and selection reachability spec
       files:    tests/nvim/mcp_context_spec.lua
       covers:   c-3
       depends_on: t-1, t-6
       description: With the session started, drive the real JSON-RPC dispatcher
                 (`server.state.handlers["tools/call"]`) against a stub client for the
                 vendored context tools over a modified buffer.
       contract: `tools/call checkDocumentDirty { filePath = <open file> }` returns
                 `isDirty = true` while the buffer has unwritten edits and `false` after
                 `:w` — if the tool surface is not registered by our start path (or a
                 wrapper suppresses `tools.setup`), the call returns
                 `-32601 Tool not found` and the spec fails.
       contract: `tools/call getCurrentSelection` returns `success = true` with `filePath`
                 equal to the open buffer, and after visual marks are set and
                 `selection.get_visual_selection_from_marks()` is flushed, the returned
                 `text` equals the *unsaved* edited line — not the line on disk. This is
                 the whole of c-3: if Claude were reading disk, the assertion on the
                 edited text fails.
       contract: after `:CodriverStart`, `selection.state.tracking_enabled == true` — the
                 wrapper must not disable `track_selection`; if it does, the selection
                 tools go permanently empty and this fails.
       contract: `tools/list` includes `getCurrentSelection`, `getLatestSelection` and
                 `checkDocumentDirty` — the surface Claude discovers, asserted by name.

  t-11 Headless status and checkhealth spec
       files:    tests/nvim/status_spec.lua
       covers:   c-4
       depends_on: t-1, t-6, t-7
       contract: with the server up and no client, `vim.fn.execute("CodriverStatus")`
                 contains the live port and a not-connected phrase; with
                 `is_claude_connected` stubbed true, the same command's output matches the
                 connected phrase and no longer matches the not-connected one — two
                 distinguishable states through the real command, not just the formatter.
       contract: `vim.cmd("checkhealth codriver")` produces a buffer containing the live
                 port, the lockfile path under the harness `CLAUDE_CONFIG_DIR`, a
                 connected-client count, and a Claude-CLI line; it contains `:CodriverStart`
                 and does **not** contain `ClaudeCodeStart` — proves the report is
                 codriver's own (t-7) and its advice points at a command that exists.
       contract: `:CodriverStatus` before any start reports not running and does not
                 create a lockfile or a server (a status query must be side-effect free).
       note:     the *genuinely* connected state (a real `claude` CLI completing the MCP
                 handshake) is only observable with the CLI installed and a live terminal,
                 so it is human-checkable. The headless proxy above stubs
                 `is_claude_connected` at the snapshot boundary; combined with t-9's proof
                 that the CLI is launched with the right port, that is the closest
                 assertable substitute.

  t-12 Headless coexistence and command-surface spec
       files:    tests/nvim/coexistence_spec.lua,
                 tests/fixtures/claudecode/lua/claudecode/init.lua,
                 tests/fixtures/claudecode/plugin/claudecode.lua
       covers:   c-6, c-7
       depends_on: t-1, t-6
       description: A fixture standing in for a real claudecode.nvim install — a
                 `lua/claudecode/init.lua` that sets a sentinel and a
                 `plugin/claudecode.lua` that registers `:ClaudeCodeStart` — prepended to
                 runtimepath alongside codriver.
       contract: `require("claudecode")` returns the fixture table (sentinel global set)
                 and is not the same table as `require("codriver.vendor.claudecode")` —
                 if the require-rewrite regresses, one shadows the other and this fails.
       contract: after `require("codriver").setup({})`, the fixture's `:ClaudeCodeStart`
                 still runs the fixture's handler (it sets a distinct global) and the
                 command count for `^ClaudeCode` is exactly the fixture's — if codriver
                 registers or *deletes* `ClaudeCode*` commands, it has damaged the other
                 plugin and this fails. (Deletion is why suppression must be interception,
                 not `nvim_del_user_command`.)
       contract: every value in `commands.map` exists in `nvim_get_commands({})`, and every
                 name the capture shim recorded is a key of `commands.map` — an upstream
                 re-sync that adds or renames a vendored command fails this drift
                 assertion instead of silently dropping the command from `:Codriver*`.
       contract: re-exported options survive: `CodriverSend` keeps `range`, `CodriverAdd`
                 keeps `nargs = "+"` and `complete = "file"`, `CodriverSendText` keeps
                 `bang = true` — losing them breaks `:'<,'>CodriverSend` and
                 `:CodriverSendText!` in ways no smoke test would notice (c-7).
       contract: with the session started, `:CodriverAdd README.md` puts one entry in
                 `vendor.state.mention_queue` whose `file_path` is the repo-relative
                 `README.md` — proves the re-exported handler is the vendored one and
                 reaches the @-mention path, not a stub.
       contract: `:CodriverDiffAccept` with no diff open, and `:CodriverSelectModel` with
                 `vim.ui.select` stubbed to cancel, both complete without raising —
                 the diff/model handlers are wired, not just named.
```

## Coverage

| Criterion | Tasks |
|---|---|
| c-1 single start command reports port; re-start reports existing session | t-5, t-8 |
| c-2 start launches CLI already connected, no manual env/port/lockfile | t-5, t-9 |
| c-3 Claude reads unsaved buffer contents + active visual selection | t-10 |
| c-4 status surface distinguishes listening from connected | t-4, t-7, t-11 |
| c-5 stop shuts down server + removes lockfile; restart succeeds | t-5, t-8 |
| c-6 coexists with a real claudecode.nvim — no module/command shadowing | t-3, t-6, t-12 |
| c-7 vendored context + diff commands reachable as `:Codriver*` | t-3, t-6, t-12 |
| c-8 auto-start opt-in; default leaves no server and no lockfile | t-2, t-6, t-8 |

t-1 covers no criterion by itself; it is the precondition for the headless half of
c-1, c-2, c-3, c-4, c-5, c-6, c-7 and c-8. 8/8 criteria covered.

## Judgment calls

- **Fixed the headless runner before writing any wrapper code.** Chose a wave-1
  infrastructure task over spreading harness setup across the specs that need it. Rejected:
  appending scripts to `mise.toml`'s `test-nvim` one at a time — `mise run test` would go
  green with red specs on disk, which is the failure mode this lens exists to prevent.
- **Suppress vendored commands by intercepting `nvim_create_user_command`, not by deleting
  the commands afterwards.** Deletion is testable but *wrong*: with a real claudecode.nvim
  on runtimepath, `nvim_del_user_command("ClaudeCodeStart")` removes the other plugin's
  command and breaks c-6. Interception also hands us the vendored handlers for c-7's
  re-export as a by-product, and it makes "no `:ClaudeCode*` was ever created" a
  positively assertable claim rather than an absence.
- **Structured returns everywhere; formatting only at the edge.** `session.start/stop`
  return tables and `status.describe` is pure, so c-1/c-4/c-5's real logic is asserted in
  busted (fast, deterministic) and the headless specs only have to prove the wiring. The
  rejected alternative — session functions that `vim.notify` directly — would have pushed
  every one of those contracts into message-scraping under nvim.
- **The vendored module is reached through a call-time `require`, never cached at module
  load.** This exists purely so `package.loaded["codriver.vendor.claudecode"] = fake` works
  in busted; it also keeps the existing "requiring codriver does not wake the protocol
  layer" assertion true. Rejected: an explicit dependency-injection parameter on every
  wrapper function — more ceremony, same testability.
- **`covers` on `commands.map` drift is a test, not documentation.** The map is asserted
  against the live captured command set (t-12) so a future `vendor-sync.sh` run that adds
  or renames an upstream command fails a test rather than quietly shipping a missing
  `:Codriver*` command. Rejected: a hand-maintained list in VENDOR.md.
- **`auto_start` is forced false downward and re-implemented upward.** The wrapper never
  passes `auto_start = true` to the vendored config even when the user opts in; it calls
  `session.start()` itself after setup. Rejected: forwarding the flag when the codriver
  option is set — it would make c-8's "vendored auto_start is always false" untestable as
  a single invariant and reintroduce the lockfile-per-nvim-instance path through a
  different door.
- **`CLAUDE_CONFIG_DIR` is redirected to a temp dir by the harness.** Without it,
  `lockfile.lock_dir` is `~/.claude/ide` (computed at module load), so the suite would
  create and delete lockfiles in the developer's live Claude config while a real session
  might be running. This forces harness-before-vendor require ordering in every headless
  spec, which the selfcheck asserts.
- **The "connected" half of c-4 is honestly only partly headless.** A real handshake needs
  the `claude` CLI, so the connected line is asserted with `is_claude_connected` stubbed,
  and the CLI-launch correctness that would produce a real handshake is asserted
  separately in t-9. Stated as a limitation rather than papered over with a weaker
  "integration test exists" claim.
- **No README/docs task.** No criterion asks for it and the lens is verification; the
  command surface is pinned by t-12's assertions instead. Flagging it as a deliberate
  omission, not an oversight.
