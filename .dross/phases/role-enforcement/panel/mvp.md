# mvp lens

Phase role-enforcement — 6 tasks across 3 waves

Three new wrapper modules (`policy`, `enforce`, `settings`), one hook script, one
wiring change, one end-to-end check. Nothing else: no `codriver.hook.*` subtree,
no user-facing allowlist config (deferred), no docs task.

Agreed constant across tasks: the hook entrypoint lives at
`scripts/codriver-hook.lua` and is invoked as
`nvim --clean --headless -l <plugin_root>/scripts/codriver-hook.lua`.

```
Wave 1

  t-1  Decide allow/deny for one tool call
       files:    lua/codriver/policy.lua, tests/codriver/policy_spec.lua
       covers:   c-2, c-3, c-4, c-5, c-7
       desc:     Pure `policy.decide(call, state)` -> { decision, reason }. Gates
                 Edit/Write/MultiEdit/NotebookEdit and Bash on the role in
                 `state`; Bash passes only via the read-only allowlist. Owns the
                 refusal wording. No vim.*, so it runs under the busted stub.
       contract:
         - if the navigator gate inverts, decide({tool="Edit"}, {live=true, role="navigator"})
           stops returning "deny", or the same call with role="driver" returns "deny"
         - if the refusal wording drifts off the locked decision, the reason string
           stops containing "navigator", stops stating the block is harness-level and
           not retryable, or starts naming a handover command (`:Codriver*` handover
           does not exist yet — the assertion is that the reason matches no
           handover-command pattern)
         - if the Bash allowlist degrades into a deny-list, any of `sh -c 'echo x > f'`,
           `eval "$CMD"`, `python3 -c "open('f','w')"`, `sed -i '' s/a/b/ f`,
           `tee f`, `git commit -m x`, `find . -name '*.lua' -delete` returns "allow"
           while navigator
         - if read-only invocations stop passing, any of `rg todo lua/`, `ls -la`,
           `cat README.md`, `git status --short`, `git log --oneline -5`,
           `git diff HEAD` returns "deny" while navigator (c-5)
         - if chaining or substitution slips past the head-token check,
           `git status && rm -rf x`, `git log; rm x`, `` cat `rm x` `` or
           `ls $(rm x)` returns "allow"; and if segmenting is dropped entirely,
           `git log | head -20` returns "deny" (both halves of the same rule)
         - if the configured test command stops being honoured, decide with
           state.test_command = "mise run test" returns "allow" for exactly
           `mise run test`, and "deny" for `mise run format` and for
           `mise run test; rm -rf .luarocks`
         - if fail-closed inverts, decide({tool="Edit"}, {live=true, role=nil}) or
           {live=true, role="captain"} returns "allow" instead of "deny" (c-7)
         - if the no-session path fails closed, decide({tool="Edit"}, nil) or
           {live=false} returns "deny" — a plain `claude` run in this repo with
           Neovim down must still be able to write (locked no_session_behaviour)
         - if the vendored Neovim MCP tools get swept into the gate,
           decide({tool="mcp__claudecode__openDiff"}, navigator) returns "deny" —
           locked nvim_write_tools keeps openDiff/saveDocument/close_tab/
           closeAllDiffTabs available

  t-2  Publish live role state to a session file
       files:    lua/codriver/enforce.lua, tests/nvim/enforce_state_check.lua
       covers:   c-6, c-7, c-8
       desc:     `enforce.attach()` writes `stdpath("state")/codriver/<pid>.json`
                 ({role, pid, address, test_command}), rewrites it from a
                 `role.on_change` listener, and removes it on VimLeavePre.
                 `enforce.read(path)` returns the three-way missing / unreadable /
                 parsed result the hook's fail-closed ladder needs.
                 `enforce.launch_env()` yields CODRIVER_STATE_FILE +
                 CODRIVER_NVIM_ADDRESS; `enforce.notify_refusal(payload)` is the
                 RPC entry point that raises the Neovim notification.
                 Headless because it touches vim.json / vim.fn / vim.uv, which the
                 busted stub deliberately does not carry.
       contract:
         - if the file stops tracking the live role, role.set("driver") after
           attach() leaves the on-disk `role` at "navigator", or role.set back to
           navigator leaves it at "driver" — the file IS c-6's live channel
         - if the liveness fields are dropped, the written JSON lacks `pid` equal to
           vim.fn.getpid() or `address` equal to a non-empty v:servername (attach
           must call serverstart() when v:servername is empty, or the hook has
           nowhere to push c-8's notification)
         - if read() collapses its two failure modes, read("<no such file>") and
           read(<file containing "{not json">) return the same thing — the hook
           allows on the first and denies on the second, so one result value for
           both makes c-7 and no_session_behaviour indistinguishable
         - if the file outlives the session, a child `nvim --clean --headless` that
           runs attach() then :qa leaves the state file on disk — a stale file with
           a recycled pid would enforce against an unrelated Claude
         - if launch_env() drops a key, its table lacks CODRIVER_STATE_FILE or
           CODRIVER_NVIM_ADDRESS, or either value is empty — both channels reach
           Claude only through the launch environment (locked role_channel)
         - if the notification stops naming the operation,
           notify_refusal({tool="Edit", target="lua/codriver/init.lua"}) produces no
           vim.notify at WARN level, or one whose text contains neither "Edit" nor
           the target path (c-8)
         - if attach() is not idempotent, calling it twice registers two on_change
           listeners and one role.set writes the file twice (plugin-manager double
           setup)

  t-3  Write the PreToolUse hook into settings.local.json
       files:    lua/codriver/settings.lua, tests/nvim/settings_hook_check.lua
       covers:   c-1
       desc:     `settings.install(root)` merges codriver's PreToolUse entry
                 (matcher "Edit|Write|MultiEdit|NotebookEdit|Bash", command
                 `nvim --clean --headless -l <plugin_root>/scripts/codriver-hook.lua`)
                 into `<root>/.claude/settings.local.json`, preserving everything
                 already there. `root` is a parameter precisely so a check can
                 point it at a temp directory.
       contract:
         - if the merge clobbers the user's file, installing over the repo's real
           settings.local.json (copied into a temp root) drops any of its 22
           permissions.allow entries, or loses a top-level key it did not write
         - if install is not idempotent, running it twice produces a different file
           the second time, or leaves two PreToolUse entries carrying codriver's
           command — the hook is written on every session start, so a non-idempotent
           merge grows the file without bound
         - if a rival PreToolUse entry is dropped, installing over a file that
           already has an unrelated PreToolUse matcher leaves that matcher absent
         - if the registered command points nowhere, the `command` string's script
           path is not readable on disk — a typo'd path yields a hook that Claude
           silently skips, which reads as enforcement working until it is tested
         - if malformed existing JSON is overwritten rather than refused,
           install(root) over a file containing `{"permissions":` returns success or
           rewrites the file, instead of raising with the path named
         - if the target path drifts, install(<temp root>) writes anything under the
           repository's own .claude/ — every check in tests/nvim runs with cwd at
           the repo root

Wave 2 (depends on wave 1)

  t-4  Add the hook entrypoint script
       files:    scripts/codriver-hook.lua, tests/nvim/hook_cli_check.lua
       covers:   c-2, c-3, c-4, c-5, c-6, c-7, c-8
       depends:  t-1, t-2
       desc:     Reads the PreToolUse payload from stdin, resolves
                 CODRIVER_STATE_FILE / CODRIVER_NVIM_ADDRESS, decides liveness
                 (state file present + its pid alive), calls policy.decide, prints
                 the hookSpecificOutput JSON, and on deny pushes
                 enforce.notify_refusal over the RPC address. The check drives the
                 real command as a subprocess with real stdin.
       contract:
         - if the deny path stops being a permission-layer denial, running the
           command with an Edit payload and a navigator state file yields stdout
           that does not parse as JSON, or lacks
           hookSpecificOutput.permissionDecision == "deny" with a non-empty
           permissionDecisionReason (c-2, c-3)
         - if the role is read at launch rather than at call time, rewriting the
           state file to "driver" between two otherwise identical runs of the same
           command yields the same verdict twice (c-6)
         - if liveness inverts, a state file whose pid is a dead process yields
           "deny" for Edit (must allow — locked no_session_behaviour), or a state
           file whose pid is this process yields "allow" for Edit (must deny)
         - if the unlaunched case fails closed, running with CODRIVER_STATE_FILE
           unset returns anything other than allow — this is the plain `claude`
           run in this repo with Neovim down
         - if fail-closed is lost end to end, a live state file containing
           `{"pid": <alive>}` with no role field yields "allow" for Edit (c-7)
         - if the Bash gate is not reached through the CLI, a Bash payload with
           `printf x >> README.md` yields "allow", or one with `git status --short`
           and one with the configured test command yield "deny" (c-4, c-5)
         - if the hook itself touches the workspace, the Edit payload's target file
           changes size or content across the run — the hook is a decision, not an
           actor (c-2)
         - if the notification is not pushed, a deny run against a live
           CODRIVER_NVIM_ADDRESS leaves the receiving Neovim with no recorded
           refusal notification (c-8)
         - if a failed push is allowed to fail open, pointing CODRIVER_NVIM_ADDRESS
           at a dead socket makes the command exit non-zero or emit no decision —
           the deny must still be printed
         - if the script grows a toolchain dependency, running it with PATH stripped
           to the directory holding `nvim` fails — it runs under `--clean` with no
           mise, no luarocks and no user config

  t-5  Wire enforcement into setup and session start
       files:    lua/codriver/init.lua, lua/codriver/config.lua,
                 tests/codriver/config_spec.lua, tests/nvim/wiring_check.lua
       covers:   c-1, c-6, c-8
       depends:  t-2, t-3
       desc:     `setup()` accepts the new top-level `test_command` key and calls
                 `enforce.attach()`; `session.ensure_server()`'s caller installs the
                 settings entry and merges `enforce.launch_env()` into the vendored
                 `env` config before the terminal opens, so the CLI is launched with
                 both channels already set.
       contract:
         - if the launch environment loses a channel, the captured terminal env at
           open time (same capture-table provider as tests/nvim/terminal_env_check)
           lacks CODRIVER_STATE_FILE or CODRIVER_NVIM_ADDRESS alongside the existing
           CLAUDE_CODE_SSE_PORT (c-1)
         - if codriver's keys are overwritable, setup({ claudecode = { env = {
           CODRIVER_STATE_FILE = "/tmp/nope" } } }) reaches the terminal with the
           user's value, or a user's unrelated `env` key is dropped by the merge
         - if the settings write moves off the session path, `:CodriverStart` into a
           temp project root leaves no .claude/settings.local.json, or the file is
           written before the state file exists (a hook registered ahead of its
           state channel denies nothing and explains nothing)
         - if the new option escapes validation, config.resolve({ test_command = 42 })
           returns instead of raising, or resolve({ test_commnd = "x" }) stops being
           rejected as an unknown top-level key, or resolve({}).codriver.test_command
           is anything but nil
         - if attach() is not called by setup, role.set("driver") after
           `require("codriver").setup({})` leaves no state file to read (c-6)
         - if the refusal notification is not reachable, an RPC call to
           `require("codriver.enforce").notify_refusal({...})` against the running
           instance raises instead of notifying (c-8)

Wave 3 (depends on wave 2)

  t-6  End-to-end refusal through the generated settings
       files:    tests/nvim/role_enforcement_check.lua
       covers:   c-1, c-2, c-3, c-4, c-5, c-6, c-8
       depends:  t-4, t-5
       desc:     Starts a real session in a temp project root, reads the hook
                 command back out of the generated settings.local.json, and runs
                 that exact command against Edit and Bash payloads. The only place
                 the generated registration, the live role and the byte-identity
                 guarantee are proven together.
       contract:
         - if the generated registration is not what enforces, the command string
           read out of the generated settings.local.json fails to produce a deny for
           an Edit payload while navigator — every other check invokes the script
           by a path it composed itself (c-1, c-2)
         - if a refused edit is not byte-identical, the target file's contents and
           mtime differ before and after the denied Edit and the denied
           `printf x >> <file>` Bash call (c-2, c-4)
         - if the decision is not role-driven, the same payload — including one
           whose text explicitly instructs the edit — does not flip verdict when
           `role.set("driver")` / `role.set("navigator")` runs between two
           invocations of the already-launched command (c-3, c-6)
         - if read-only work is collateral damage, `git status --short`, `rg role
           lua/` and the configured `test_command` payloads return anything but
           allow while navigator (c-5)
         - if the user has to read the Claude terminal to learn about the refusal,
           the deny leaves no notification recorded in the Neovim instance —
           captured by replacing vim.notify before the run and asserting the text
           names the blocked tool (c-8)
         - if the session's own surface regresses, the temp root's
           settings.local.json holds exactly one codriver PreToolUse entry after a
           start / stop / start cycle
```

## Coverage

| criterion | tasks |
|---|---|
| c-1 launch with permission config applied, no hand-editing | t-3, t-5, t-6 |
| c-2 edit refused before it runs, file byte-identical | t-1, t-4, t-6 |
| c-3 permission-layer denial with codriver's reason | t-1, t-4, t-6 |
| c-4 shell write refused on the same grounds | t-1, t-4, t-6 |
| c-5 read / search / test still succeed | t-1, t-4, t-6 |
| c-6 decision reads live role at call time | t-2, t-4, t-5, t-6 |
| c-7 undeterminable role inside a live session refuses | t-1, t-2, t-4 |
| c-8 refusal raises a Neovim notification | t-2, t-4, t-5, t-6 |

Every task carries at least one criterion; there is no enabler task in this phase
(t-1 of session-bringup already built the headless runner).

## Judgment calls

- **Hook interpreter is `nvim --clean --headless -l`, not sh+jq or python3.** The
  payload has to be parsed as JSON and the Bash allowlist needs real string work;
  `nvim` is the one interpreter guaranteed present for a Neovim plugin's user, and
  it gives `vim.json`, `vim.uv` and RPC for free. Rejected: jq (extra dependency),
  python3 (not guaranteed), luajit from `.luarocks` (dev-tree-only).
- **Matcher lists the gated tools rather than matching every tool.** `Edit|Write|
  MultiEdit|NotebookEdit|Bash` keeps a ~60ms nvim start off every Read and Grep,
  which is most of c-5's felt behaviour. Rejected: matcher `*` with a fast-path
  allow, which is safer against a future write-capable tool name but taxes every
  read. The escape risk is named here so the judge can overrule it cheaply — it is
  a one-string change.
- **Liveness is "state file present and its pid alive", not an RPC connect.** Locked
  `role_channel` keeps the hot path off a blocking round-trip, and `kill(pid, 0)`
  is the cheapest sound answer. Rejected: connecting to CODRIVER_NVIM_ADDRESS to
  prove Neovim is up.
- **Three-way ladder for the fail-closed split:** state file missing → allow (no
  session); present with a dead pid → allow (crashed Neovim); present, pid alive,
  role unreadable → deny. Unparseable JSON denies, because a file we cannot read is
  a file whose pid we cannot check, and c-7 is the tie-break.
- **Settings are installed on session start, not in `setup()`.** c-1 is about
  *starting a session*, and installing at setup would write `.claude/` into every
  repo the user opens Neovim in. Accepted cost: the existing headless checks start
  sessions with cwd at the repo root and so rewrite this repo's own (gitignored,
  untracked) settings.local.json — harmless because the merge is idempotent, and
  t-3's contract pins that.
- **State file at `stdpath("state")/codriver/<pid>.json`.** Session-scoped by pid,
  under a directory Neovim already owns, and sandboxed by the harness's HOME
  redirect for free. Rejected: `$CLAUDE_CONFIG_DIR` (that is Claude's namespace)
  and a repo-local dotfile (leaks into the working tree, and the spec already
  accepts exactly one mutated tree file).
- **`test_command` is a new top-level codriver option defaulting to nil.** Locked
  `bash_policy` says "a codriver-configured test command", and the phase must not
  guess `mise run test` for every user's repo. Rejected: hardcoding the dross
  project's command, and shipping the fuller user-facing allowlist config (deferred
  to role-visibility).
- **Bash allowlist is head-token-per-segment plus a metacharacter refusal.** Reject
  the whole command on `>`, `` ` ``, `$(`, `<(`, `&` or a newline; then split on
  `|`, `&&`, `;` and require every segment's first token to be allowlisted (with a
  git subcommand allowlist inside it). Rejected: parsing the command properly,
  which is the deny-list trap the locked decision rules out.
- **Flat module names — `policy.lua`, `enforce.lua`, `settings.lua` — not a
  `codriver.hook.*` subtree.** Three modules do not need a namespace, and
  `codriver.hook` + `codriver.hook.policy` coexisting as a file and a directory is
  a readability cost with no payoff.
- **One end-to-end task (t-6) survives the merge pass.** It is the only place the
  generated registration, the live role flip and byte-identity meet; folding it
  into t-4 would leave the phase proving the script works when invoked by a path
  the test composed itself, which is not c-1.
