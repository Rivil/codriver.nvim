# Panel draft — lens: mvp

Phase session-bringup — 5 tasks across 2 waves

```
Wave 1
  t-1  Split codriver options from vendored config
       files:    lua/codriver/config.lua
                 tests/codriver/config_spec.lua
       covers:   c-8
       contract: config.resolve({ claudecode = { auto_start = true } }) still yields
                 claudecode.auto_start == false (busted, config_spec) — the vendored
                 flag is forced off and is not user-reachable; resolve({ auto_start =
                 true }) sets codriver.auto_start == true; resolve({ typo = 1 }) errors
                 naming the unknown top-level key; resolve({}) leaves
                 claudecode.track_selection == true (c-3 depends on it) and
                 claudecode.terminal.provider == "auto".

  t-2  Add session start/stop/status module
       files:    lua/codriver/session.lua
                 tests/nvim/session_smoke.lua
                 mise.toml
       covers:   c-1, c-2, c-3, c-4, c-5
       description:
                 session.start() starts the vendored server, then opens the vendored
                 terminal so the CLI inherits CLAUDE_CODE_SSE_PORT/ENABLE_IDE_INTEGRATION;
                 returns { started, port, already_running }. session.stop() delegates to
                 vendored stop. session.status() returns { running, port, lockfile,
                 connected, client_count } with listening and connected as separate
                 fields. mise.toml `test-nvim` becomes a loop over tests/nvim/*.lua so
                 later tasks add scripts without touching mise.
       contract: headless (tests/nvim/session_smoke.lua, CLAUDE_CONFIG_DIR pointed at a
                 temp dir so ~/.claude/ide is untouched):
                 - first start() returns already_running == false and a port in
                   config.port_range; the lockfile <tmp>/ide/<port>.lock is readable and
                   its JSON carries the same authToken the server was started with
                 - second start() returns already_running == true with the SAME port and
                   does not error or spawn a second server (c-1)
                 - after start(), the terminal provider was asked to open with an env
                   table containing CLAUDE_CODE_SSE_PORT == tostring(port) and
                   ENABLE_IDE_INTEGRATION == "true" (stub terminal provider records the
                   call) — if the wrapper ever opens the terminal *before* the server,
                   the recorded port is nil and this fails (c-2)
                 - with a scratch buffer holding unwritten lines and visual marks set,
                   the getCurrentSelection tool handler returns those unsaved lines and
                   the marked range, and getOpenEditors lists the buffer — proving
                   selection tracking was enabled by start() and the MCP tools are
                   registered (c-3)
                 - status() with the server up and no client: running == true,
                   connected == false, client_count == 0 (c-4)
                 - stop() then: lockfile path no longer readable, status().running ==
                   false, and a subsequent start() in the same nvim returns started ==
                   true with a fresh lockfile (c-5)

Wave 2 (depends t-1, t-2)
  t-3  Expose Codriver commands, suppress ClaudeCode ones
       files:    lua/codriver/commands.lua
                 lua/codriver/init.lua
                 tests/codriver/commands_spec.lua
                 tests/nvim/commands_smoke.lua
       covers:   c-1, c-4, c-5, c-6, c-7, c-8
       description:
                 commands.lua stubs vim.api.nvim_create_user_command for the duration of
                 the vendored setup() call, capturing every (name, callback, opts) instead
                 of registering it, then re-registers each under a Codriver-prefixed name.
                 Start/Stop/Status are dropped from the captured set and replaced by
                 codriver's own, which call session.*. init.lua resolves opts through
                 config, runs the intercepted vendored setup, registers commands, and
                 calls session.start() only when codriver auto_start is true.
       depends:  t-1, t-2
       contract: busted (commands_spec): the pure name mapper turns "ClaudeCodeDiffAccept"
                 -> "CodriverDiffAccept", "ClaudeCode" -> "Codriver", and returns nil for
                 the three replaced names, so a renamed upstream command cannot silently
                 keep its ClaudeCode name.
                 headless (tests/nvim/commands_smoke.lua), after
                 require("codriver").setup({}):
                 - nvim_get_commands({ builtin = false }) contains ZERO name matching
                   ^ClaudeCode (c-6) — a regression that lets the vendored registration
                   through fails here
                 - it contains CodriverStart, CodriverStop, CodriverStatus, Codriver,
                   CodriverSend (range == true), CodriverAdd, CodriverDiffAccept,
                   CodriverDiffDeny, CodriverSelectModel (c-7); CodriverSend and
                   CodriverAdd dispatch into the vendored at-mention path (recorded on a
                   stub server), so a capture that drops the callback fails
                 - no lockfile exists under CLAUDE_CONFIG_DIR and the server is not
                   running after setup({}) (c-8 default); :CodriverStart then reports the
                   port it bound, and running :CodriverStart again echoes the existing
                   port rather than raising (c-1)
                 - setup({ auto_start = true }) in a fresh nvim leaves the server running
                   with a lockfile present (c-8 opt-in)
                 - :CodriverStop removes the lockfile and :CodriverStart afterwards
                   succeeds in the same nvim (c-5)
                 - :CodriverStatus echoes one line naming the port and stating Claude is
                   not connected while no client has handshaked (c-4)

  t-4  Add codriver health check
       files:    lua/codriver/health.lua
                 tests/nvim/health_smoke.lua
       covers:   c-4
       description:
                 :checkhealth codriver renders session.status() — Neovim/CLI/terminal
                 provider prerequisites, then listening state (port, lockfile path) and
                 connection state as separate report entries. Does not reuse the vendored
                 health module, which conflates the two.
       depends:  t-2
       contract: headless (tests/nvim/health_smoke.lua): with the session started and no
                 client connected, the :checkhealth codriver buffer contains a line
                 reporting the bound port AND a distinct line reporting no Claude client
                 connected; with no session started it reports the server as not listening
                 and names :CodriverStart. If the two states are ever collapsed into one
                 entry, the "distinct line" assertion fails (c-4).

  t-5  Prove coexistence with real claudecode.nvim
       files:    tests/fixtures/claudecode.nvim/lua/claudecode/init.lua
                 tests/fixtures/claudecode.nvim/plugin/claudecode.lua
                 tests/nvim/coexist_smoke.lua
       covers:   c-6
       description:
                 A minimal stand-in claudecode.nvim (provides lua/claudecode/ and
                 registers :ClaudeCodeStart) is put on runtimepath alongside codriver in
                 a separate headless nvim; the script asserts neither side is shadowed.
                 Separate process because tests/nvim/vendor_smoke.lua asserts the bare
                 `claudecode` namespace is never loaded.
       depends:  t-3
       contract: headless (tests/nvim/coexist_smoke.lua): with both plugins on rtp and
                 codriver.setup({}) called, require("claudecode") resolves to the fixture
                 (its sentinel field is present) while
                 require("codriver.vendor.claudecode") resolves to the vendored module,
                 and :ClaudeCodeStart is the fixture's command while every Codriver* name
                 is codriver's. If the vendored require-rewrite regressed, or if
                 codriver's command interception leaked a ClaudeCode* registration that
                 overwrote the fixture's, this script fails.
```

## Coverage

| Criterion | Tasks |
|---|---|
| c-1 single start command reports port; re-run reports existing | t-2, t-3 |
| c-2 start launches CLI already connected, no manual env | t-2 |
| c-3 unsaved buffer contents + visual selection retrievable | t-2 |
| c-4 listening vs connected as two states | t-2 (data), t-3 (`:CodriverStatus`), t-4 (checkhealth) |
| c-5 stop tears down server + lockfile, restart works | t-2, t-3 |
| c-6 coexists with real claudecode.nvim | t-3 (namespace by construction), t-5 (proof) |
| c-7 vendored context/diff commands under `:Codriver*` | t-3 |
| c-8 auto-start opt-in, nothing listening by default | t-1 (forced off), t-3 (opt-in wiring) |

All 8 criteria covered.

## Judgment calls

- **Command surface: intercept `nvim_create_user_command` during vendored `setup()`** rather than let vendor register and then delete/rename after. Rejected delete-after-register because `nvim_get_commands` exposes a Lua callback only as the string `"<Lua function>"` — the handlers would be unreachable, so "re-exporting the vendored handlers" (locked) would be impossible without hand-editing `vendor/` (forbidden by r-02).
- **Re-export every captured vendored command mechanically, not a curated list.** A prefix swap is less code than enumerating c-7's named subset, and it makes c-7 true by construction plus survives an upstream re-sync adding a command. Rejected hand-listing the five commands c-7 names.
- **One `session.status()` consumed by both `:CodriverStatus` and health**, rather than each surface probing vendored state itself. Two probes would let the two surfaces disagree about "connected", which is exactly the distinction c-4 buys.
- **No standalone "tests" task.** Every task ships its own headless script; the only test-only task is t-5, and only because c-6 needs a second nvim process (vendor_smoke asserts the bare `claudecode` namespace is never loaded, so it cannot host a real claudecode.nvim).
- **`mise.toml`'s `test-nvim` becomes a loop over `tests/nvim/*.lua`** — one edit, in t-2, instead of a mise task per new script. Rejected adding `test-session`/`test-commands`/`test-health` tasks.
- **No `lua/codriver/terminal.lua` wrapper.** The locked `terminal_provider` decision keeps provider `"auto"`, so c-2 needs nothing but ordering — server up, then the vendored `terminal.open()`, which already injects the env. Any wrapper here would be speculative structure.
- **Codriver's `auto_start` lives at the top level; the vendored one is forced off unconditionally** (not merely defaulted off), so a user writing `claudecode = { auto_start = true }` cannot resurrect launch-time server start through the pass-through — the opt-in path is codriver's key only.
- **Test scripts point `CLAUDE_CONFIG_DIR` at a temp dir.** `lockfile.lua` reads it at module load, so the smoke scripts must set it before the first require; otherwise a headless run writes lockfiles into the developer's real `~/.claude/ide`.
