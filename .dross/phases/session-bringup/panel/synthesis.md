# session-bringup — cold-judge synthesis

Three drafts read; none authored here. Every path and vendored-behaviour claim below
was checked against the tree.

## Scores

| dimension | risk | mvp | verification |
|---|---|---|---|
| **criteria coverage** | 8/8, each criterion owned by 2+ tasks; c-3 rests on a single test-only task (t-8) | 8/8 on paper only — t-2 covers c-1..c-5 and t-3 covers six criteria, so a red task names five criteria at once | 8/8 with each criterion split into a unit-level owner and a headless owner; criteria were written as contracts first, then reduced to tasks |
| **test-contract specificity** | very high; best negative paths (bind failure leaves no lockfile, stop idempotent, restore-on-error by identity comparison) | moderate; assertions bundled in prose blocks, c-3's "returns those unsaved lines" is the vaguest contract in the panel | very high; one `contract` line per assertion, each with an explicit "if X regresses this fails" clause, and honest that the real handshake is not headless-observable |
| **granularity** | 9 tasks, one failure class each; t-6 over-bundles (session commands + auto-start + terminal pre-flight, 4 criteria, one commit) | 5 tasks, too coarse — t-2 is server + terminal + MCP context + status in one commit; not atomically committable | 12 tasks, finest and most commit-shaped; slight over-split — t-7 (health) ships no test of its own and defers every contract to t-11 |
| **wave correctness** | 4 waves, deps sound; deliberately serialises t-6 after t-4 to avoid a same-wave `commands.lua` conflict (right call); t-9's `depends` line and its wave header disagree | 2 waves, weakest — t-2 sits in wave 1 while itself editing `mise.toml`'s runner, so the first task both builds the harness and depends on it | 4 waves, ordering correct (harness first, all headless specs last) but under-packed: wave 2 holds one task |

**Skeleton: verification.** It is the only draft where every criterion has a named,
mechanically-checkable owner at both the pure-Lua and headless level, and the only one
whose task boundaries are already commit-sized. risk is a close second and supplies most
of the grafts below; mvp is rejected as a skeleton because its two largest tasks are not
gateable — a failing `t-2` would leave you guessing which of five criteria broke.

## Merged plan

Phase session-bringup — 12 tasks across 4 waves

```
Wave 1
  t-1  Add headless check runner and harness                    [verification + risk]
       files:    tests/nvim/harness.lua,
                 tests/nvim/harness_selfcheck_check.lua, mise.toml
       covers:   (enabler — no criterion; unlocks the headless half of c-1..c-8)
       desc:     `mise run test-nvim` today runs one hardcoded script
                 (mise.toml:132), so any new headless file is dead code until the
                 runner iterates the directory. Harness supplies assertion helpers
                 and a per-run temp HOME/CLAUDE_CONFIG_DIR.
       contract: - `mise run test-nvim` runs every `tests/nvim/*_check.lua` plus
                   vendor_smoke.lua, each in its own nvim process, and exits
                   non-zero on the first failure — a WebSocket server leaked by one
                   check cannot make the next one pass                       [risk]
                 - the busted glob in `[tasks.test]` excludes `tests/nvim`, so a
                   headless check is never handed to bare LuaJIT. As written,
                   mise.toml:102 globs `tests -name "*_spec.lua"`; hence the
                   `*_check.lua` naming                                      [risk]
                 - the selfcheck spawns a child `nvim --clean --headless -l` on a
                   script whose harness assertion fails and asserts a non-zero exit
                   — if `harness.expect` degrades to print-and-continue, every
                   downstream contract silently passes            [verification]
                 - harness asserts `CLAUDE_CONFIG_DIR` (and hence
                   `vendor.claudecode.lockfile.lock_dir`, computed at module load,
                   lockfile.lua:12,20) resolves inside the run's temp dir and the
                   lock dir is empty before any start; it refuses to run otherwise
                   — a check can never unlink a live session's lockfile under the
                   real `~/.claude/ide`                       [risk+verification]
                 - "check files discovered == files on disk", so adding a red check
                   cannot leave `mise run test` green               [verification]

  t-2  Resolve and validate codriver options       [verification+risk+mvp]
       files:    lua/codriver/config.lua, tests/codriver/config_spec.lua
       covers:   c-8
       desc:     Pure resolver splitting top-level codriver keys from nested
                 `claudecode = { … }`, rejecting unknown top-level keys, forcing the
                 vendored `auto_start` false. Returns `{ codriver = …, claudecode = … }`.
       contract: - `resolve({ auto_strt = true })` raises naming `auto_strt` and
                   returns nothing — no caller proceeds to vendored setup with a
                   half-understood table                        [verification+risk]
                 - `resolve({}).claudecode.auto_start == false` **and**
                   `resolve({ claudecode = { auto_start = true } }).claudecode.auto_start
                   == false`, with one warning naming the top-level option — the
                   vendored default is `true` (config.lua:12), and the locked
                   explicit-start decision cannot be overridden through the nested
                   table                                        [verification+risk]
                 - `resolve({ auto_start = true })` yields `codriver.auto_start == true`
                   with `claudecode.auto_start == false` — the opt-in is never
                   forwarded downward; the wrapper starts the session itself
                                                                    [verification]
                 - `resolve({}).claudecode.track_selection == true` (c-3 depends on
                   it) and `claudecode.terminal.provider == "auto"` preserved, and
                   `{ terminal = { provider = "snacks" } }` survives nesting
                                                                [mvp+verification]
                 - mutating any nested table in the returned value leaves the
                   caller's `opts` untouched (deep copy) — vendored setup mutates
                   what it is handed (`opts.terminal = t`), and a lazy.nvim `opts`
                   reused across reloads must not drift                      [risk]
                 - the spec runs against the existing minimal `vim` stub with no
                   additions; if `config.lua` reaches for any `vim.*`, it errors on
                   a nil field                                  [verification+risk]

  t-3  Capture and re-export vendored commands              [verification+risk]
       files:    lua/codriver/commands.lua, tests/codriver/commands_spec.lua
       covers:   c-6, c-7
       desc:     `commands.capture(fn)` swaps `nvim_create_user_command` for a
                 recorder while `fn` runs, plus `commands.map` (vendored name →
                 `:Codriver*`) and `commands.register(captured)`. Takes the api
                 table as an argument so it is testable without Neovim. Scoped to
                 the `setup()` call only, never around start/stop.
       contract: - a `capture()` body calling `nvim_create_user_command` three times
                   yields three records with name/handler/opts intact and creates
                   zero real commands                              [verification]
                 - captured entries keep their flags, not just names: `range = true`
                   for ClaudeCodeSend, `nargs = "+"` / `complete = "file"` for
                   ClaudeCodeAdd, `bang = true` for ClaudeCodeSendText     [risk]
                 - when the body raises, `nvim_create_user_command` and
                   `nvim_create_augroup` are restored to the exact original function
                   values (identity comparison) and the error propagates — a leaked
                   shim would swallow every command any other plugin registers
                   afterwards                                    [risk+verification]
                 - `commands.map` has 15 keys, one per vendored command (verified
                   against vendor/claudecode/init.lua: ClaudeCode, Focus, Open,
                   Close, Send, Add, TreeAdd, SendText, DiffAccept, DiffDeny,
                   CloseAllDiffs, SelectModel, Start, Stop, Status), no value
                   beginning with `ClaudeCode`, and no two keys sharing a target
                                                                    [verification]
                 - `nvim_create_augroup("ClaudeCodeShutdown", {clear=true})` inside
                   the scope creates `CodriverShutdown`; the bridge is documented
                   and asserted NOT usable around start/stop, because
                   selection.lua:151 clears `ClaudeCodeSelection` by literal name
                   and a renamed group would make `stop()` throw            [risk]

  t-4  Format listening and connected status lines             [verification]
       files:    lua/codriver/status.lua, tests/codriver/status_spec.lua
       covers:   c-4
       desc:     Pure `status.describe(snapshot)` over
                 `{ listening, port, connected, client_count, lockfile }`, producing
                 the one-line `:CodriverStatus` answer.
       contract: - the three snapshots (not listening / listening+not connected /
                   listening+connected) produce three distinct strings, and the
                   not-connected line does not match the pattern the connected
                   assertion uses
                 - `describe{ listening = true, port = 12345, … }` contains "12345"
                   — the in-flow answer names the port without a health split
                 - `describe{ listening = true, connected = false, client_count = 1 }`
                   still reports *not* connected — a TCP client that never completed
                   the MCP handshake is not Claude (matches the handshake-aware
                   check at vendor/claudecode/init.lua:43)

Wave 2 (depends t-4)
  t-5  Add session start/stop/snapshot wrapper           [verification + risk]
       files:    lua/codriver/session.lua, tests/codriver/session_spec.lua
       covers:   c-1, c-2, c-5
       depends:  t-4
       desc:     Start/stop/snapshot over the vendored module, returning structured
                 results (`{ started, already_running, port, error }`) rather than
                 printing. Reaches the vendored module only through a call-time
                 `require`, so specs can inject a fake into `package.loaded`.
       contract: - with a fake vendor whose `state.server` is set, `session.start()`
                   returns `already_running = true` with the same port and the
                   fake's `start` counter stays 0 — the vendored path returns
                   `false, "Already running"` (init.lua:479), which must not surface
                   as a failure (c-1)                             [verification]
                 - `session.start()` on a fresh fake calls `vendor.start(false)`
                   once, then the fake terminal's `open` exactly once, in that order
                   — terminal-first means the CLI gets no port (see t-9)
                                                                [verification+mvp]
                 - when the fake `vendor.start` returns `false, "port unavailable"`,
                   `session.start()` returns `{ started = false, error = … }` and
                   `terminal.open` is never called — no Claude terminal without a
                   server behind it                               [verification]
                 - `session.stop()` with no server returns `stopped = false` without
                   raising and never calls the fake's `stop`; with a server it
                   returns the port it tore down, and it reports success even when
                   the lockfile was already deleted underneath it   [verification+risk]
                 - `status.describe(session.snapshot())` on a fake with one
                   handshake-complete client yields the connected line — pins the
                   snapshot keys to exactly what t-4 consumes       [verification]

Wave 3
  t-6  Wire setup: options, command surface, auto-start, pre-flight
                                                    [verification+risk+mvp]
       files:    lua/codriver/init.lua, tests/codriver/init_spec.lua
       covers:   c-1, c-2, c-6, c-7, c-8
       depends:  t-2, t-3, t-5
       desc:     `setup(opts)` resolves options (t-2), runs the vendored `setup`
                 inside the capture shim (t-3), registers only `:Codriver*` —
                 Start/Stop/Status bound to session/status, the rest to captured
                 vendored handlers — then starts the session iff
                 `codriver.auto_start`. Terminal-opening commands carry a pre-flight
                 guard that brings the server up first.
       contract: - after `setup({})` with a fake vendor, every recorded command name
                   matches `^Codriver` and none matches `^ClaudeCode`  [verification]
                 - the rename map is asserted complete against the capture: a
                   captured vendored command with no `:Codriver*` entry fails — the
                   tripwire for an upstream re-sync adding a command          [risk]
                 - `setup({ auto_start = true })` calls `session.start` once;
                   `setup({})` calls it zero times (c-8)             [verification]
                 - `:Codriver` / `:CodriverOpen` / `:CodriverFocus` /
                   `:CodriverSelectModel` invoked with no session start the server
                   first — the vendored env builder omits `CLAUDE_CODE_SSE_PORT`
                   when the server is down (terminal.lua:369), which would launch a
                   Claude that can never connect back (c-2)                 [risk]
                 - calling `setup({})` twice leaves exactly one set of `:Codriver*`
                   commands, no `:ClaudeCode*`, and does not raise (plugin-manager
                   double setup)                                            [risk]
                 - the existing init_spec assertion that `require("codriver")` leaves
                   `package.loaded["codriver.vendor.claudecode"]` nil still holds
                   (tests/codriver/init_spec.lua:28)                 [verification]

  t-7  Add codriver checkhealth report                    [risk+mvp+verification]
       files:    lua/codriver/health.lua, tests/nvim/health_check.lua
       covers:   c-4
       depends:  t-1, t-4, t-5
       desc:     `require("codriver.health").check()` for `:checkhealth codriver` —
                 Neovim floor, `claude` CLI, terminal provider, then listening /
                 lockfile / connected as separate lines, built from
                 `session.snapshot()`, not the vendored report (which conflates the
                 two and routes through its own log level).
       contract: - with the server up and no client, the listening line is OK and
                   the connected line is not OK — two distinguishable states
                                                                  [risk+mvp]
                 - with no session, the advice mentions `:CodriverStart` and the
                   report contains no `:ClaudeCodeStart` / `:ClaudeCodeStop` string
                   — the vendored health advice names commands codriver does not
                   register                                   [risk+verification]
                 - when the server is listening but its `<port>.lock` has been
                   unlinked behind its back, the report shows an error naming the
                   missing lockfile path                                    [risk]
                 - `require("codriver.health").check` exists under the module name
                   Neovim's checkhealth resolves, so the report is reachable as
                   `:checkhealth codriver` rather than only via the vendored section
                                                                            [risk]

Wave 4 (depends t-1, t-6, t-7)
  t-8  Headless session lifecycle and auto-start checks    [verification + risk]
       files:    tests/nvim/session_lifecycle_check.lua,
                 tests/nvim/autostart_off_check.lua,
                 tests/nvim/autostart_on_check.lua
       covers:   c-1, c-5, c-8
       depends:  t-1, t-6
       desc:     Three scripts (auto-start needs a fresh process per scenario)
                 driving real `:CodriverStart` / `:CodriverStop` against the real
                 server and the harness's temp lock dir.
       contract: - `vim.fn.execute("CodriverStart")` output contains the port from
                   `server.get_status().port`, and exactly one `*.lock` exists
                                                                    [verification]
                 - a second `:CodriverStart` leaves `get_status().port` unchanged,
                   still exactly one lockfile, and its output matches an
                   already/existing-session pattern with no error-level line (c-1)
                                                               [verification+risk]
                 - with `port_range = {min = P, max = P}` and P pre-bound by the
                   check via `vim.uv.new_tcp`, start returns a failure naming the
                   exhausted range, status reports not-listening, and the lock dir
                   stays empty — a bind failure never leaves a lockfile advertising
                   a dead port                                              [risk]
                 - after `:CodriverStop`, `get_status().running == false` and
                   `filereadable(<lock_dir>/<port>.lock) == 0`; a following
                   `:CodriverStart` returns a fresh port and one lockfile (c-5)
                                                                    [verification]
                 - `:CodriverStop` with nothing running prints a not-running message
                   and leaves the lock dir empty, without raising  [verification]
                 - selection tracking follows the session: after start,
                   `nvim_get_autocmds({group = "ClaudeCodeSelection"})` is non-empty;
                   after stop it is empty and stop did not throw — catches the
                   augroup-rename trap in t-3                                [risk]
                 - autostart_off: after `setup({})`, `running == false` and zero
                   `*.lock`. autostart_on: after `setup({ auto_start = true })`,
                   `running == true` and exactly one lockfile; and a child nvim that
                   auto-starts then `:qa` leaves an empty lock dir — the VimLeavePre
                   shutdown still fires after the rename to `CodriverShutdown`
                                                               [verification+risk]

  t-9  Headless Claude-terminal environment check                [verification]
       files:    tests/nvim/terminal_env_check.lua
       covers:   c-2
       depends:  t-1, t-6
       desc:     `setup({ claudecode = { terminal = { provider = <capture table> } } })`
                 with a custom table provider (setup/open/close/simple_toggle/
                 focus_toggle/get_active_bufnr/is_available), then `:CodriverStart`.
       contract: - the provider's `open` is called exactly once by `:CodriverStart`
                   and the captured env has
                   `CLAUDE_CODE_SSE_PORT == tostring(get_status().port)`,
                   `ENABLE_IDE_INTEGRATION == "true"`,
                   `FORCE_CODE_TERMINAL == "true"` (terminal.lua:364-369) — if the
                   terminal launches before the server is listening the port key is
                   absent, which is exactly c-2's failure
                 - `open` must not be called before `session.snapshot().listening`
                   is true — ordering, not just presence                    [risk]
                 - the captured command's first token is `claude` (or the configured
                   `terminal_cmd`) and no wrapper module assigns
                   `CLAUDE_CODE_SSE_PORT` itself — one source, no drift
                 - the captured `no_proxy`/`NO_PROXY` include `127.0.0.1`
                   (terminal.lua:383-387) — proves the wrapper still routes through
                   the vendored env builder rather than hand-rolling an env table

  t-10 Headless buffer and selection reachability check    [verification + risk]
       files:    tests/nvim/mcp_context_check.lua
       covers:   c-3
       depends:  t-1, t-6
       desc:     With the session started, drive the real JSON-RPC dispatcher
                 (`server.state.handlers["tools/call"]`) against a stub client over
                 a modified buffer. Verification-only; a defect found here is fixed
                 in `lua/codriver/session.lua`, never in `vendor/`.
       contract: - `tools/list` includes `getCurrentSelection`, `getLatestSelection`,
                   `checkDocumentDirty`, `saveDocument` and `getOpenEditors` — a
                   config that switched off `track_selection`, or a start path that
                   skipped `tools.setup`, fails here          [verification+risk]
                 - `checkDocumentDirty { filePath = <open file> }` returns
                   `isDirty = true` while the buffer has unwritten edits and `false`
                   after `:w`; a missing surface returns `-32601 Tool not found`
                                                                    [verification]
                 - with a file opened, edited in-buffer and NOT written, then
                   visually selected, `getCurrentSelection` returns `text` equal to
                   the in-buffer edited line and not the on-disk line — this is the
                   whole of c-3                              [verification+risk]
                 - `getCurrentSelection` on a buffer with no selection returns
                   `success = true` with `isEmpty = true` rather than raising — the
                   no-selection path must not reach Claude as a tool error   [risk]
                 - after `:CodriverStart`, `selection.state.tracking_enabled == true`
                                                                    [verification]

  t-11 Headless status and checkhealth check                     [verification]
       files:    tests/nvim/status_check.lua
       covers:   c-4
       depends:  t-1, t-6, t-7
       contract: - with the server up and no client, `vim.fn.execute("CodriverStatus")`
                   contains the live port and a not-connected phrase; with
                   `is_claude_connected` stubbed true, the output matches the
                   connected phrase and no longer matches the not-connected one —
                   two distinguishable states through the real command
                 - `vim.cmd("checkhealth codriver")` produces a buffer containing the
                   live port, the lockfile path under the harness
                   `CLAUDE_CONFIG_DIR`, a connected-client count and a Claude-CLI
                   line; it contains `:CodriverStart` and not `ClaudeCodeStart`
                 - `:CodriverStatus` before any start reports not running and creates
                   no lockfile and no server — a status query is side-effect free
       note:     the genuinely connected state needs the `claude` CLI completing a
                 real handshake, so it stays human-checkable; the headless proxy
                 stubs `is_claude_connected` at the snapshot boundary, and t-9 proves
                 the CLI is launched with the right port. Stated as a limitation,
                 not papered over.

  t-12 Headless coexistence and command-surface drift check
                                                      [verification + risk + mvp]
       files:    tests/nvim/coexistence_check.lua,
                 tests/fixtures/claudecode.nvim/lua/claudecode/init.lua,
                 tests/fixtures/claudecode.nvim/plugin/claudecode.lua
       covers:   c-6, c-7
       depends:  t-1, t-6
       desc:     A fixture standing in for a real claudecode.nvim install — it claims
                 `lua/claudecode/`, the `:ClaudeCode*` names and the
                 `ClaudeCodeShutdown` augroup, each carrying a marker — prepended to
                 runtimepath alongside codriver. Separate process because
                 tests/nvim/vendor_smoke.lua:53-57 asserts the bare `claudecode`
                 namespace is never loaded. A fake, not a real upstream checkout:
                 c-6's failure modes are all name collisions.
       contract: - `require("claudecode")` returns the fixture table (marker set) and
                   is not the same table as `require("codriver.vendor.claudecode")`
                                                      [verification+risk+mvp]
                 - after `require("codriver").setup({})` the fixture's
                   `:ClaudeCodeStart` still runs the fixture's handler (asserted by
                   invoking it and reading its marker) and the `^ClaudeCode` command
                   count is exactly the fixture's — if codriver registers *or
                   deletes* `ClaudeCode*`, it has damaged the other plugin. Deletion
                   is why suppression must be interception       [verification+risk]
                 - the fixture's `ClaudeCodeShutdown` autocmd survives codriver
                   setup: `nvim_get_autocmds({group = "ClaudeCodeShutdown"})` still
                   contains the fixture's entry, because the bridge renamed the
                   vendored group instead of re-creating it with `clear = true`
                   (init.lua:452) and destroying the rival's exit handler — the
                   failure mode is silent: the rival never removes its lockfile
                                                                            [risk]
                 - every value in `commands.map` exists in `nvim_get_commands({})`
                   and every captured name is a key of `commands.map` — an upstream
                   re-sync that adds or renames a command fails this drift assertion
                                                                    [verification]
                 - re-exported options survive: `CodriverSend` keeps `range`,
                   `CodriverAdd` keeps `nargs = "+"` / `complete = "file"`,
                   `CodriverSendText` keeps `bang = true` — losing them breaks
                   `:'<,'>CodriverSend` and `:CodriverSendText!` in ways no smoke
                   test notices (c-7)                          [verification+risk]
                 - with the session started, `:CodriverAdd README.md` puts one entry
                   in `vendor.state.mention_queue` whose `file_path` is the
                   repo-relative `README.md`, and `:'<,'>CodriverSend` queues one
                   entry naming the selected file — proves the re-exported handler
                   is the vendored one (the queue holds when no client is connected,
                   init.lua:139-149)                          [verification+risk]
                 - `:CodriverDiffAccept` with no diff open and `:CodriverSelectModel`
                   with `vim.ui.select` stubbed to cancel both complete without
                   raising — the diff/model handlers are wired, not just named
                                                                    [verification]
                 - `session.start()` with the fixture loaded still writes one
                   lockfile and reports a port, and `:checkhealth codriver` still
                   resolves to codriver's module rather than the fixture's   [risk]
```

### Coverage

| criterion | tasks |
|---|---|
| c-1 single start command reports port; re-start reports existing session | t-5, t-6, t-8 |
| c-2 CLI launched already connected, no manual env/port/lockfile | t-5, t-6, t-9 |
| c-3 unsaved buffer contents + active visual selection retrievable | t-10 |
| c-4 listening vs connected as two distinguishable states | t-4, t-7, t-11 |
| c-5 stop shuts down server + removes lockfile; restart succeeds | t-5, t-8 |
| c-6 coexists with a real claudecode.nvim — no module/command shadowing | t-3, t-6, t-12 |
| c-7 vendored context + diff commands reachable as `:Codriver*` | t-3, t-6, t-12 |
| c-8 auto-start opt-in; default leaves no server and no lockfile | t-2, t-6, t-8 |

8/8. t-1 owns no criterion; it is the precondition for the headless half of all eight.

### Grafts applied to the skeleton

- `*_check.lua` naming + `tests/nvim` excluded from the busted glob, and the harness
  refusing to run outside its temp lock dir (risk t-1) — fixes a real defect in the
  skeleton, see disagreement 3.
- Restore-by-identity on error, flag preservation, and the `ClaudeCodeShutdown` rename
  (risk t-3), plus the rival-shutdown-survival assertion (risk t-9).
- Deep-copy of `opts`, and `track_selection`/`provider` preservation (risk t-2, mvp t-1).
- Port-range-exhaustion and stop-idempotence negative paths (risk t-5).
- Terminal-command pre-flight guard and its ordering assertion (risk t-6).
- A test file for the health task, so it gates itself (risk t-7 / mvp t-4).
- Selection-augroup lifecycle across start/stop (risk t-5), empty-selection tool path
  (risk t-8), tool-registry-by-name (risk t-8).
- Fixture path `tests/fixtures/claudecode.nvim/` (mvp t-5 dir shape) and mvp's
  separate-process rationale for the coexistence check.

## Disagreements

**1. Task count — 5 (mvp) vs 9 (risk) vs 12 (verification).**
mvp bundles server + terminal + MCP context + status into one task covering c-1..c-5, and
a second covering six criteria; risk splits by failure class; verification splits pure
modules from headless proofs. **Provisional: 12.** Stake: whether a red test names one
criterion or five, and whether each task is an atomic commit that a test gate can
authorise — under this repo's commit-safety rules mvp's t-2 cannot be gated meaningfully.
Cost of the pick: five of the twelve tasks are test-only files.

**2. Where session lifecycle logic is asserted — busted with a fake vendor, or headless
against the real server.**
verification asserts c-1/c-5's decision logic in busted by injecting a fake into
`package.loaded` (t-5), keeping headless for wiring only; risk and mvp assert the same
behaviour only against the real WebSocket server in nvim. **Provisional: verification —
fake-vendor busted spec in t-5, real-server proof retained in t-8.** Stake: fast and
deterministic, but a fake vendor whose shape drifts from `vendor.state` would let t-5 go
green against a contract the real module no longer honours; t-8 is what keeps that honest,
so dropping t-8's overlap is not safe.

**3. Headless file naming and the busted glob — `*_check.lua` (risk) vs `*_spec.lua`
(verification) vs `*_smoke.lua` / `tests/nvim/*.lua` (mvp).**
`mise.toml:102` globs `find tests … -name "*_spec.lua"` and hands the result to busted
under bare LuaJIT, so verification's naming would sweep every headless check into the
wrong runner, where it fails on `vim.api`. **Provisional: risk — `*_check.lua`, plus an
explicit `tests/nvim` exclusion in `[tasks.test]`.** Stake: a whole class of checks either
failing spuriously or silently not running; this is the skeleton's one outright defect.

**4. Does a terminal-opening command auto-start the server?**
risk makes `:Codriver` / `:CodriverOpen` / `:CodriverFocus` / `:CodriverSelectModel` bring
the server up first; mvp folds terminal-opening into `session.start()` and says nothing
about the other entry points; verification asserts only `:CodriverStart`'s path. **Provisional:
risk's pre-flight guard, contracted in t-6 and asserted in t-9.** Stake: a user who types
`:Codriver` before `:CodriverStart` gets a Claude launched without
`CLAUDE_CODE_SSE_PORT` (terminal.lua:369 only sets it when the server has a port) — it can
never connect back, which is precisely c-2 failing.

**5. Is `lua/codriver/status.lua` a separate pure module?**
verification makes status wording a pure module with its own busted spec (t-4) and pins
`session.snapshot()`'s keys against it; risk and mvp fold the wording into
session/commands and assert it only through the real `:CodriverStatus` echo. **Provisional:
keep t-4 separate.** Stake: c-4's three distinguishable states are asserted cheaply and
exhaustively in busted rather than by scraping echo output under nvim — at the cost of one
more module and one extra wave dependency (t-5 → t-4).

**6. Rename the vendored `ClaudeCodeShutdown` augroup?**
risk renames it to `CodriverShutdown` inside the capture scope and asserts the rival's
shutdown autocmd survives; mvp and verification never touch augroups. **Provisional: adopt
the rename.** Stake: `init.lua:452` creates it with `clear = true`, so whichever plugin
sets up second silently destroys the other's VimLeavePre handler and the loser leaves a
stale lockfile pointing at a dead server — a c-6 violation no draft but risk detects.
Residual: `ClaudeCodeSelection` and `ClaudeCodeDiffCleanup` stay shared, deliberately
(renaming Selection would make vendored `stop()` throw, selection.lua:151).

**7. Does the health task carry its own test?**
verification's t-7 lists only `lua/codriver/health.lua` and defers every contract to t-11;
risk and mvp each ship a headless health check with the task. **Provisional: risk/mvp —
`tests/nvim/health_check.lua` lands with t-7.** Stake: a task with no gate of its own
cannot be committed under the observed-result rule, and t-7 would otherwise sit two waves
away from its only assertion.

**8. Fixture location — `tests/nvim/fixtures/claudecode.nvim/` (risk) vs
`tests/fixtures/claudecode.nvim/` (mvp) vs `tests/fixtures/claudecode/` (verification).**
None exists yet. **Provisional: `tests/fixtures/claudecode.nvim/`.** Stake: low on its own,
but it must sit outside `tests/nvim/` or the t-1 runner will try to execute the fixture's
`init.lua` as a check — which is why risk's nesting is rejected despite risk owning the
runner design.
