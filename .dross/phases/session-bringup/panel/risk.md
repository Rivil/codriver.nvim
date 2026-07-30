# session-bringup — risk lens

Lens: **failure modes drive the graph.** Every task owns one class of breakage and
proves it with an assertion a headless run can make. The three things that can
silently ruin this phase are (a) the vendored `setup()` registering global names
we said we would suppress, (b) a session whose server, lockfile and terminal env
fall out of sync, and (c) tests that write into the developer's real
`~/.claude/ide` and clobber a live session. Each gets an owner below.

```
Phase session-bringup — 9 tasks across 4 waves

Wave 1
  t-1  Build headless check harness and rival fixture
       files:    tests/nvim/harness.lua,
                 tests/nvim/fixtures/claudecode.nvim/lua/claudecode/init.lua,
                 tests/nvim/fixtures/claudecode.nvim/plugin/claudecode.lua,
                 mise.toml
       covers:   (enabler — no criterion)
       desc:     Assertion helpers + per-check temp HOME/CLAUDE_CONFIG_DIR + a
                 `mise run test-nvim` loop that runs each tests/nvim/*_check.lua
                 in its own nvim process. Fixture is a minimal fake
                 claudecode.nvim that claims `lua/claudecode/`, the
                 `:ClaudeCode*` command names and the `ClaudeCodeShutdown`
                 augroup, each carrying a marker so a test can tell whose is
                 whose.
       contract: - harness refuses to run (non-zero exit, no server started) if
                   `codriver.vendor.claudecode.lockfile.lock_dir` resolves
                   outside the run's temp dir — a check can never unlink a live
                   session's lockfile under the real ~/.claude/ide
                 - a check file that fails one assertion makes `mise run test`
                   exit non-zero (verified by a deliberately failing scratch
                   assertion during the task, not left in the tree)
                 - each check runs in a fresh nvim process: a WebSocket server
                   leaked by one check cannot make the next one pass
                 - the busted file glob in `[tasks.test]` excludes tests/nvim,
                   so a headless check is never swept into the LuaJIT run
                   (naming convention `*_check.lua`, not `*_spec.lua`)

  t-2  Resolve and validate codriver options
       files:    lua/codriver/config.lua, tests/codriver/config_spec.lua
       covers:   c-8
       desc:     Pure-Lua resolver splitting top-level codriver keys from the
                 nested `claudecode` table, whitelisting top-level keys, and
                 forcing the vendored `auto_start` to false unconditionally
                 while surfacing codriver's own opt-in separately.
       contract: - `resolve({ auto_stat = true })` (typo'd key) raises an error
                   naming the offending key and returns nothing, so no caller
                   can proceed to vendored setup with a half-understood table
                 - `resolve({ claudecode = { auto_start = true } })` returns
                   vendor config with `auto_start == false` and records one
                   warning naming the top-level `auto_start` option — the
                   locked "explicit start by default" decision cannot be
                   overridden through the nested table
                 - `resolve({}).vendor.auto_start == false` and
                   `resolve({}).codriver.auto_start == false` (c-8 default)
                 - mutating any nested table in the returned value leaves the
                   caller's `opts` untouched (deep copy) — the vendored setup
                   mutates what it is handed (`opts.terminal = t`), and a
                   lazy.nvim `opts` table reused across reloads must not drift
                 - resolver touches no `vim.*` beyond nothing at all: the spec
                   runs under busted with the existing tiny stub, unextended

  t-3  Suppress and capture vendored registration
       files:    lua/codriver/vendor_bridge.lua,
                 tests/codriver/vendor_bridge_spec.lua
       covers:   c-6, c-7
       desc:     A scoped interception used only around the vendored `setup()`
                 call: `nvim_create_user_command` records name/handler/opts
                 instead of registering, and `nvim_create_augroup` rewrites a
                 `ClaudeCode*` group name to `Codriver*`. Takes the api table as
                 an argument so it is testable without Neovim. Restores both
                 functions unconditionally, error or not.
       contract: - running the bridge over a fake api that mimics the vendored
                   setup registers zero user commands and returns all 15
                   captured names (ClaudeCodeStart/Stop/Status/Send/TreeAdd/Add/
                   ClaudeCode/Focus/Open/Close/SendText/DiffAccept/DiffDeny/
                   CloseAllDiffs/SelectModel) with their opts intact
                 - a captured entry keeps `range = true` for ClaudeCodeSend,
                   `nargs = "+"` and `complete = "file"` for ClaudeCodeAdd, and
                   `bang = true` for ClaudeCodeSendText — the flags, not just
                   the names, survive capture
                 - when the wrapped function raises, `api.nvim_create_user_command`
                   and `api.nvim_create_augroup` are restored to the exact
                   original function values (identity comparison) and the error
                   propagates — a failed setup cannot leave a live nvim with a
                   command-swallowing api
                 - `nvim_create_augroup("ClaudeCodeShutdown", {clear=true})`
                   inside the scope creates `CodriverShutdown`; the bridge is
                   documented and asserted NOT to be usable around start/stop,
                   because `selection.lua` clears `ClaudeCodeSelection` by
                   literal name and a renamed group would make `stop()` throw

Wave 2 (depends t-1, t-2, t-3)
  t-4  Wire setup through bridge, expose :Codriver* pass-throughs
       files:    lua/codriver/init.lua, lua/codriver/commands.lua,
                 tests/nvim/commands_check.lua
       covers:   c-6, c-7
       desc:     `setup()` resolves options (t-2), runs vendored setup inside the
                 bridge (t-3), then registers the captured context/terminal/diff
                 handlers under `:Codriver*` names from an explicit rename map.
                 Session commands are deliberately excluded here (t-6).
       depends:  t-1, t-2, t-3
       contract: - after `require("codriver").setup({})` in headless nvim,
                   `vim.fn.exists(":ClaudeCodeSend")` and every other
                   `:ClaudeCode*` name is 0, while `:CodriverSend`,
                   `:CodriverAdd`, `:CodriverTreeAdd`, `:Codriver`,
                   `:CodriverFocus`, `:CodriverOpen`, `:CodriverClose`,
                   `:CodriverSendText`, `:CodriverDiffAccept`,
                   `:CodriverDiffDeny`, `:CodriverCloseAllDiffs` and
                   `:CodriverSelectModel` all exist (c-7)
                 - the map is asserted complete against the capture: a captured
                   vendored command with no `:Codriver*` entry fails the check —
                   this is the tripwire for an upstream re-sync that adds a
                   command, so drift surfaces as a red test, not a missing feature
                 - `nvim_get_commands` for `:CodriverSend` reports
                   `range == "."`/nargs preserved from the vendored opts, so a
                   `:'<,'>CodriverSend` cannot fail with E481
                 - calling `setup({})` twice leaves exactly one set of
                   `:Codriver*` commands, no `:ClaudeCode*`, and does not raise
                   (plugin-manager double-setup / config reload)
                 - `:checkhealth`-style discovery aside, `package.loaded` after
                   setup contains no bare `claudecode` or `claudecode.*` key
                   (extends the existing vendor_smoke invariant past setup)

  t-5  Implement session start/stop lifecycle invariants
       files:    lua/codriver/session.lua, tests/nvim/session_check.lua
       covers:   c-1, c-4, c-5
       desc:     Codriver-owned start/stop/state on top of the vendored
                 start/stop: distinguishes "already running" from failure,
                 exposes port + lockfile path + listening/connected as separate
                 facts, and guarantees stop leaves no lockfile behind.
       depends:  t-1, t-2
       contract: - `session.start()` twice returns, the second time, an
                   `already_running` outcome carrying the same port as the first
                   and no error — the vendored `start()` returns
                   `false, "Already running"` for this case and must not be
                   reported as a failure (c-1)
                 - after two starts, the lock dir contains exactly one
                   `<port>.lock` — a second start never writes a second lockfile
                 - with `port_range = {min = P, max = P}` and P pre-bound by the
                   check itself via `vim.uv.new_tcp`, `session.start()` returns a
                   failure naming the exhausted range, `session.status()` reports
                   not-listening, and the lock dir stays empty — a bind failure
                   never leaves a lockfile advertising a dead port
                 - `session.stop()` removes the `<port>.lock` file
                   (`filereadable == 0`) and reports success even when the file
                   was already deleted out from under it; `session.stop()` with
                   no session returns a not-running outcome without raising
                 - start → stop → start in one nvim succeeds and reports a port
                   (c-5), and after the second start the new `<port>.lock` exists
                 - selection tracking follows the session: after `start()`,
                   `nvim_get_autocmds({group = "ClaudeCodeSelection"})` is
                   non-empty; after `stop()` it is empty and `stop()` did not
                   throw — this is the assertion that catches the augroup-rename
                   trap in t-3 (a renamed group makes vendored
                   `nvim_clear_autocmds` fail on a nonexistent group)
                 - `session.status()` returns `listening` and `connected` as two
                   independent booleans plus port and lockfile path; with the
                   server up and no client, `listening == true` and
                   `connected == false` (c-4 state model, one source of truth
                   for both surfaces)

Wave 3
  t-6  Register session commands and auto-start
       files:    lua/codriver/commands.lua, lua/codriver/init.lua,
                 tests/nvim/session_commands_check.lua
       covers:   c-1, c-2, c-4, c-8
       desc:     `:CodriverStart` (starts, echoes port, or echoes the live
                 session), `:CodriverStop`, `:CodriverStatus` (one-line echo from
                 `session.status()`), plus the opt-in launch-time start and a
                 pre-flight guard that brings the server up before any
                 terminal-opening command so the Claude CLI always inherits
                 `CLAUDE_CODE_SSE_PORT`.
       depends:  t-4, t-5
       contract: - `:CodriverStart` with no session echoes a message containing
                   the actual listening port; run again immediately it echoes a
                   message naming the same port and does not emit an error-level
                   notification (c-1)
                 - `:CodriverStatus` output with the server up and no client
                   differs from its output with a client connected, and both
                   differ from the stopped output — three distinguishable
                   strings, asserted on the captured echo, with listening and
                   connected named separately (c-4)
                 - `:Codriver` / `:CodriverOpen` / `:CodriverFocus` /
                   `:CodriverSelectModel` invoked with no session start the
                   server first: the check stubs the vendored terminal
                   provider's `open` and asserts the env table it received
                   contains `CLAUDE_CODE_SSE_PORT` equal to the live port and
                   `ENABLE_IDE_INTEGRATION = "true"` — the vendored env builder
                   omits the port when the server is down, which would launch a
                   Claude that can never connect back (c-2)
                 - `:CodriverStart` opens the terminal only after the server is
                   listening: the stubbed provider's `open` must not be called
                   before `session.status().listening` is true (ordering, not
                   just presence)
                 - `setup({})` in a child nvim leaves the lock dir empty and
                   `session.status().listening == false`; `setup({auto_start =
                   true})` in a child nvim leaves exactly one `<port>.lock`
                   while it runs (c-8, both directions)
                 - a child nvim that runs `setup({auto_start = true})` then
                   `:qa` leaves an empty lock dir — the VimLeavePre shutdown
                   still fires after the bridge renamed its augroup to
                   `CodriverShutdown`, so auto-start does not litter a lockfile
                   per nvim instance

  t-7  Add :checkhealth codriver report
       files:    lua/codriver/health.lua, tests/nvim/health_check.lua
       covers:   c-4
       desc:     Codriver's own health module reading `session.status()`:
                 Neovim floor, `claude` CLI, terminal provider, then listening /
                 lockfile / connected as separate lines with codriver's command
                 names in the advice.
       depends:  t-5
       contract: - `:checkhealth codriver` in headless nvim produces a report
                   whose lines distinguish "server listening on port N" from
                   "Claude connected" — with the server up and no client, the
                   listening line is OK and the connected line is not OK (c-4)
                 - with no session, the report's advice mentions
                   `:CodriverStart` and contains no `:ClaudeCodeStart` /
                   `:ClaudeCodeStop` string — the vendored health module's advice
                   names commands codriver does not register, so blind delegation
                   would send users to a nonexistent command
                 - when the server is listening but its `<port>.lock` has been
                   unlinked behind its back, the report shows an error naming the
                   missing lockfile path — the state where Claude cannot discover
                   an otherwise-healthy server
                 - `require("codriver.health").check` exists under the module
                   name Neovim's checkhealth resolves (`codriver.health`), so the
                   report is reachable as `:checkhealth codriver` rather than
                   only through the vendored section

  t-8  Prove unsaved-buffer and selection retrieval
       files:    tests/nvim/context_check.lua
       covers:   c-3
       desc:     Headless proof that a live session exposes the context tools
                 Claude uses. Verification-only; if it exposes a defect the fix
                 lands in lua/codriver/session.lua (complete by then) rather
                 than in vendor/.
       depends:  t-5
       contract: - after `session.start()`, the vendored tool registry contains
                   `getCurrentSelection`, `getLatestSelection`,
                   `checkDocumentDirty`, `saveDocument` and `getOpenEditors` — a
                   codriver config that switched off `track_selection` or a
                   start path that skipped `tools.setup` fails here
                 - with a file opened, edited in-buffer and NOT written, then
                   visually selected, the `getCurrentSelection` handler returns
                   JSON whose `text` is the in-buffer edited line and not the
                   on-disk line — this is the assertion that "unsaved contents"
                   actually means unsaved (c-3)
                 - the `checkDocumentDirty` handler for that buffer returns
                   `isDirty = true`, and `false` after `:w`
                 - `getCurrentSelection` on a buffer with no selection returns
                   `success = true` with `isEmpty = true` rather than raising —
                   the no-selection path must not surface to Claude as a tool error
                 - `:'<,'>CodriverSend` with the session up and no client leaves
                   exactly one entry in the vendored mention queue naming the
                   selected file — proves selection→mention wiring survives the
                   command rename, without needing a real Claude

Wave 4 (depends t-4, t-6, t-7)
  t-9  Prove coexistence with a rival claudecode.nvim
       files:    tests/nvim/coexistence_check.lua
       covers:   c-6
       desc:     Loads the t-1 fixture plugin (which owns `lua/claudecode/`, the
                 `:ClaudeCode*` names and the `ClaudeCodeShutdown` augroup)
                 alongside codriver, then asserts neither shadows the other.
       depends:  t-1, t-4, t-6, t-7
       contract: - with the fixture on runtimepath, `require("claudecode")`
                   returns the fixture's marker table, not codriver's vendored
                   module, and `require("codriver.vendor.claudecode")` is a
                   different table — module namespaces stay disjoint (c-6)
                 - the fixture's `:ClaudeCodeStart` still resolves to the
                   fixture's handler after `require("codriver").setup({})`
                   (asserted by invoking it and reading its marker global), and
                   every `:Codriver*` command exists — neither plugin's user
                   commands shadow the other's
                 - the fixture's `ClaudeCodeShutdown` autocmd survives codriver
                   setup: `nvim_get_autocmds({group = "ClaudeCodeShutdown"})`
                   still contains the fixture's entry, because the bridge renamed
                   the vendored group instead of re-creating it with
                   `clear = true` and destroying the rival's exit handler (the
                   failure mode here is silent: the rival never removes its
                   lockfile on exit)
                 - `session.start()` with the fixture loaded still writes one
                   lockfile and reports a port, and `:checkhealth codriver`
                   still resolves to codriver's module rather than the fixture's
```

## Coverage

| criterion | tasks |
|---|---|
| c-1 single start command, second start reports existing | t-5, t-6 |
| c-2 Claude launched already connected, no manual env | t-6 |
| c-3 unsaved buffer contents + visual selection reachable | t-8 |
| c-4 listening vs connected as two states | t-5 (state), t-6 (`:CodriverStatus`), t-7 (checkhealth) |
| c-5 stop shuts down + removes lockfile, restart works | t-5 |
| c-6 coexists with a real claudecode.nvim | t-3, t-4, t-9 |
| c-7 vendored context/diff commands under `:Codriver*` | t-3, t-4 |
| c-8 auto-start opt-in; nothing listening by default | t-2, t-6 |

t-1 covers no criterion: it is the harness every other contract's assertion runs
in. Without it each contract above degrades to "open nvim and look", which the
brief rightly calls a weak contract.

## Judgment calls

- **Capture-and-rename the vendored commands rather than hand-writing 15
  wrappers.** Hand-written wrappers would re-implement vendored handler logic
  (the tree-buffer branches in `handle_send_normal` alone are ~60 lines) and rot
  on every re-sync. Capture keeps the handlers byte-identical and turns "upstream
  added a command" into a failing map-completeness assertion.
- **Scope the api interception to the `setup()` call only.** Rejected: a
  permanent or start/stop-wide shim. `selection.lua:151` clears
  `ClaudeCodeSelection` by literal name, so renaming that group would make
  `stop()` throw on a nonexistent group; t-5 asserts the selection augroup
  lifecycle precisely to pin this.
- **Rename `ClaudeCodeShutdown`, accept sharing `ClaudeCodeSelection` /
  `ClaudeCodeDiffCleanup`.** The shutdown group is created with `clear = true`,
  so whichever plugin sets up second silently destroys the other's VimLeavePre
  handler — a stale lockfile with no server behind it. The selection group is
  also `clear = true` but renaming it is unsafe (above), and the diff cleanup
  group is `clear = false` so it cannot destroy anything. Residual documented,
  not hidden.
- **Force vendored `auto_start` off unconditionally; warn rather than error when
  the user sets it in the nested table.** Erroring inside `setup()` breaks nvim
  startup for a user whose only sin is a misplaced key. Unknown *top-level* keys
  do error, per the locked options_shape decision.
- **A fake claudecode.nvim fixture, not a real one.** Vendoring or
  network-fetching upstream into tests is a supply-chain and offline-CI problem;
  c-6's failure modes are all name collisions, and a fixture that claims exactly
  the colliding names (`lua/claudecode/`, `:ClaudeCode*`, `ClaudeCodeShutdown`)
  reproduces every one of them deterministically.
- **Terminal commands bring the server up instead of refusing.** Rejected:
  erroring with "start a session first". The vendored env builder omits
  `CLAUDE_CODE_SSE_PORT` when the server is down, so the refusal-free path is
  also the only one where c-2's "user sets no port by hand" holds from every
  entry point.
- **Sequence t-6 after t-4/t-5 rather than parallelising.** t-6 and t-4 both own
  `lua/codriver/commands.lua`; a same-wave conflict in the file that decides the
  entire command surface is a worse risk than the lost parallelism.
- **Rename headless checks to `*_check.lua` and exclude `tests/nvim` from the
  busted glob.** `[tasks.test]` globs `tests -name "*_spec.lua"`; a headless spec
  under the old name would be handed to bare LuaJIT and fail on `vim.api`. Cheap
  now, confusing later.
- **No README/VENDOR.md documentation task.** No criterion asks for it, and the
  brief says work backward from acceptance. Worth a follow-up, not a task here.
