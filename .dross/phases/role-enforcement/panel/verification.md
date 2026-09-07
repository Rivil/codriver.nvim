# role-enforcement — verification lens

Designed backward from the tests. Each criterion got an ideal contract first; the
task is the smallest change that makes that contract runnable.

Two structural consequences of that ordering, both deliberate:

- **Every module has a pure core and a thin IO shell.** `tests/busted_setup.lua`
  is a deliberately tiny stub and its own header forbids growing it into a vim
  mock. So the policy (`gate`), the settings merge (`claude_settings.merge`) and
  the hook's decision (`hook.evaluate`) are pure functions over plain tables,
  busted-testable against the existing stub; file IO, `serverstart`, `sockconnect`
  and `vim.notify` live in shells covered by headless checks. No task widens
  `tests/busted_setup.lua`.
- **The hook is Lua run by `nvim --clean -l`.** It is the only interpreter
  guaranteed present (this is a Neovim plugin), it gives `vim.json` and
  `vim.fn.sockconnect` for free — which is exactly what c-8's push needs — and it
  keeps the whole gate under `luacheck`/`lua-language-server`, which a `sh`+`jq`
  hook would not be.

Phase role-enforcement — 9 tasks across 3 waves

## Wave 1

```
t-1  Gate policy: tool classes and Bash allowlist
     files:    lua/codriver/gate.lua, tests/codriver/gate_spec.lua
     covers:   c-2, c-3, c-4, c-5, c-7
     contract: decide{role="navigator", tool="Edit"} returns deny — asserted by
               name for Edit, Write, MultiEdit, NotebookEdit; and a name that is
               in neither list ("FutureWriteTool") also denies, so a write tool
               Claude Code ships next month is refused rather than silently
               permitted (the allowlist is what makes c-2 sound by construction,
               same reasoning as the locked bash_policy)
     contract: if the read-only allowlist shrinks, Read / Grep / Glob /
               TodoWrite / WebFetch / WebSearch stop returning allow while
               navigator (c-5)
     contract: if the vendored nvim surface loses its exemption, the four MCP
               tool names (openDiff, saveDocument, close_tab, closeAllDiffTabs,
               under their mcp__ prefix) deny while navigator — the locked
               nvim_write_tools decision, and the tell that :CodriverDiffAccept
               went dead
     contract: Bash allow set: `rg -n pat lua/`, `git status --short`,
               `git log --oneline -5`, `ls tests`, and the configured
               test_command byte-for-byte (c-5)
     contract: Bash deny set, each asserted individually: `echo x > f`,
               `cat a >> b`, `sed -i '' s/x/y/ f`, `tee f`, `git commit -m x`,
               `git checkout -- f`, `git stash`, `rg x && rm f`, `rg x; rm f`,
               `rg $(echo x)`, "rg `id`", `sh -c 'rm f'`, `env A=1 rg x` — a
               deny-list over `rm`/`>` cannot survive any of the last five, which
               is why this is an allowlist (c-4)
     contract: if test_command matching loosens from an exact string to a prefix,
               `mise run format` is allowed when test_command is `mise run test`
     contract: if allowlisting matches on a prefix rather than the resolved
               argv[0] basename, `rgx --write f` or `/opt/evil/rg` is allowed
     contract: if enforcement leaks past the role, decide{role="driver", …}
               denies Edit, Write or `rm -rf build` — driver is unrestricted
     contract: role nil, "", or "nvigator" returns deny with the indeterminate
               reason and NOT the navigator reason — the two are distinguishable
               strings, because c-7's failure mode has to be readable in the
               refusal (c-7)
     contract: the refusal text contains "navigator", says the block is
               harness-level and not retryable, and contains no `:Codriver`
               command name — asserted with a not-contains on ":Codriver", per
               the locked refusal_message (c-3)
     contract: if gate.lua reaches for vim.fn / vim.uv / vim.json, the spec
               errors on a nil field under the existing minimal stub rather than
               passing under a widened one

t-2  Publish role state and push refusals
     files:    lua/codriver/enforce.lua, tests/codriver/enforce_spec.lua
     covers:   c-6, c-7, c-8
     contract: if the state file is not rewritten on every change, flipping
               navigator→driver→navigator leaves the on-disk role at the first
               value — publish() is asserted to have written on each call, not
               only on the first (c-6)
     contract: if the write is not temp-file-plus-rename, the module opens the
               final path for truncation — asserted at the call level, because a
               reader that catches a half-written file sees a live session with
               an unparseable role and correctly denies, turning a cosmetic
               non-atomicity into refused read-only work (c-7)
     contract: if ensure_address() stops calling serverstart() when
               vim.v.servername is empty, it returns "" — a `nvim --headless -l`
               or a build of nvim with no default server leaves c-8's push with
               nowhere to send (asserted headlessly in t-9; the busted half
               asserts the empty-servername branch is taken)
     contract: if disarm() leaves the state file behind, a plain `claude` run in
               this repo after Neovim exits is refused with no session behind it
               — the file's absence IS the no_session_behaviour signal
     contract: refused{tool="Edit", path="lua/x.lua"} emits exactly one
               vim.notify at WARN or above whose text contains both "Edit" and
               "lua/x.lua"; if it grows a return value or a blocking wait, the
               hook's fire-and-forget notify starts delaying every denied tool
               call (c-8)
     contract: the published payload carries role, test_command and pid; a
               missing key fails the spec, because hook.evaluate keys off all
               three and a silently-absent test_command turns c-5's allowed test
               command into a denial
     contract: hook_command() composes `nvim --clean -l <plugin_root>/lua/
               codriver/hook.lua` from the module's own source path — if it
               hardcodes a path or resolves against cwd, a codriver installed by
               a plugin manager registers a command that does not exist (that the
               path is real and runnable is asserted in t-7)

t-3  Merge codriver's hook into Claude settings
     files:    lua/codriver/claude_settings.lua,
               tests/codriver/claude_settings_spec.lua
     covers:   c-1
     contract: merge() over a document whose permissions.allow holds the repo's
               existing entries (20 of them at planning time) returns every one,
               in order, unchanged — this file is hand-maintained and codriver
               writing it must not cost the user their permission grants. The
               spec fixture is a copy of the real array, not a two-element
               stand-in, because the entries contain escaped parens and quotes
               that a naive re-encode mangles (c-1)
     contract: if registration is not idempotent, merging twice yields two
               PreToolUse entries naming codriver's hook — asserted by count, not
               by string equality
     contract: if a stale entry is not replaced, merging with a new plugin root
               leaves the old command string present alongside the new one; the
               match is on the entry whose command ends in /lua/codriver/hook.lua
     contract: if third-party hooks are collateral damage, an unrelated
               PreToolUse matcher and a PostToolUse block present before the
               merge are absent after
     contract: if serialization is not deterministic (stable key order, stable
               indent), encoding an already-registered document twice produces
               different bytes — without byte-stability "codriver re-registers on
               every start" becomes an unreviewable working-tree diff and the
               idempotence assertion above is untestable end to end
     contract: merging into an absent document produces a document with only the
               hooks block — no invented permissions key, no empty arrays
     contract: if unparseable input is overwritten rather than refused, a
               settings file with a trailing comma comes back as a valid
               codriver-authored document and the user's hand edits are gone —
               merge must report the parse failure to its caller instead
```

## Wave 2 (depends on wave 1)

```
t-4  Hook entry: decide, emit, notify
     files:    lua/codriver/hook.lua, tests/codriver/hook_spec.lua,
               tests/nvim/harness.lua
     covers:   c-2, c-3, c-5, c-6, c-7, c-8
     depends:  t-1, t-2
     contract: if an allowed tool emits an explicit allow, stdout is non-empty —
               it must be empty (exit 0, no JSON). An emitted
               permissionDecision:"allow" would auto-approve every tool the user
               never consented to, converting codriver from a restriction into a
               blanket permission grant. This is the single highest-value
               assertion in the phase (c-5)
     contract: if the deny payload drifts, stdout's
               hookSpecificOutput.hookEventName is not "PreToolUse" or
               permissionDecision is not "deny" — a bare non-zero exit is a
               non-blocking hook error that Claude Code allows straight through,
               so "the hook crashed" and "the hook denied" must not be the same
               observable (c-2, c-3)
     contract: if liveness is inferred from the state file instead of from the
               RPC address, evaluate() with CODRIVER_NVIM_SERVER unset returns a
               decision instead of standing down — the file is the role channel,
               the socket is the liveness channel, and conflating them makes a
               stale file from a crashed Neovim refuse a plain `claude` run
               (locked no_session_behaviour)
     contract: live socket + broken role state returns deny, asserted for three
               separate states: state file absent, state file truncated
               mid-JSON, role field "nvigator" (c-7)
     contract: if the notify failure path swallows the decision, evaluate()
               against an unreachable channel returns allow instead of deny — the
               notification is best-effort, the denial is not (c-8)
     contract: if any internal error resolves to allow while the session is live,
               a gate that raises produces an exception and a non-2 exit rather
               than a deny — evaluate() wraps the decision and converts a raise
               into the indeterminate denial (c-7)
     contract: if the script loads user configuration, a temporary
               XDG_CONFIG_HOME/nvim/init.lua planted by the harness runs during
               the hook — it must not: a user's config can take seconds or prompt,
               and it runs on every gated tool call
     contract: harness.run_hook(payload, env) is added to tests/nvim/harness.lua
               and returns { code, stdout, stderr } from the real registered
               command; if t-8 and t-9 each grow their own spawner they will drift
               apart and one of them will stop testing the registered argv

t-5  Wire the launch channel and role listener
     files:    lua/codriver/init.lua, tests/codriver/init_spec.lua
     covers:   c-1, c-6
     depends:  t-2
     contract: if the launch env stops carrying the channel, setup({}) against a
               fake vendor leaves resolved.claudecode.env without
               CODRIVER_STATE_FILE and CODRIVER_NVIM_SERVER — the hook then sees
               no session and allows every write in this repo (c-1)
     contract: if injection happens after the vendored setup rather than before,
               the variables never reach the CLI: the vendored init calls
               terminal.setup(opts.terminal, terminal_cmd, config.env) during
               setup and freezes defaults.env there — the spec asserts the env
               table the fake receives, not a later mutation of it
     contract: if a user's env is clobbered, setup({claudecode={env={FOO="1"}}})
               loses FOO; and a user value for CODRIVER_STATE_FILE is overridden
               by codriver's with exactly one warning naming the key
     contract: if every value is not a string, the vendored config.apply assert
               ("env values must be strings") fires — a port or pid injected as a
               number takes down setup()
     contract: if the role listener is not registered by setup, role.set("driver")
               afterwards leaves the published role at navigator, and the hook
               keeps denying after handover (c-6)
     contract: if cleanup is not hung off the CodriverShutdown augroup, a child
               nvim that sets up, starts and :qa leaves its state file on disk —
               same shape as the existing autostart_on VimLeavePre assertion
     contract: if setup is not re-entrant, calling it twice registers two role
               listeners and every role change publishes twice

t-6  Arm enforcement on start, disarm on stop
     files:    lua/codriver/session.lua, tests/codriver/session_spec.lua,
               lua/codriver/config.lua, tests/codriver/config_spec.lua
     covers:   c-1, c-5
     depends:  t-2, t-3
     contract: if arming happens after the terminal, the recorded call order from
               session.start() is open-then-write — the CLI can be issuing tool
               calls against a settings file that has no hook in it yet. Ordering
               is the contract, exactly as it is for the server/terminal pair
               already asserted in session_spec (c-1)
     contract: if the already_running path skips arming, deleting
               .claude/settings.local.json and running ensure_server() again
               leaves it unregistered — every :Codriver* preflight goes through
               ensure_server, so that is the one place arming is guaranteed
     contract: if the settings file is written to vim.fn.getcwd() while the
               vendored terminal launches Claude at the git root, Claude never
               reads it — the spec asserts the write path is the directory the
               vendored cwd resolution hands the terminal (c-1)
     contract: if stop does not disarm, the state file survives session.stop()
               and a plain `claude` in this repo is refused with no Neovim behind
               it; the settings entry deliberately survives (it is inert without
               the state file, per the locked settings_delivery cost)
     contract: config.resolve({test_command="mise run test"}) surfaces it under
               .codriver and NOT under .claudecode; a non-string raises naming the
               key; and resolve({test_commnd=…}) still raises as an unknown
               top-level key (the typo guard must not be weakened by the new key)
     contract: if test_command does not reach the published state, the gate's
               allowlist has no test command and c-5's "running the project's
               test command still works" fails at runtime while every unit test
               passes
```

## Wave 3 (depends on wave 2)

```
t-7  Headless launch-time enforcement check
     files:    tests/nvim/enforcement_launch_check.lua
     covers:   c-1
     depends:  t-3, t-4, t-5, t-6
     contract: if registration is not in place when the CLI launches, the capture
               terminal provider's open is called while
               <project>/.claude/settings.local.json holds no PreToolUse entry
               naming codriver's hook — each recorded provider call carries
               whether the file was armed at that moment, so late arming cannot
               be masked by a later read (c-1)
     contract: if the pre-existing file is destroyed, a settings file seeded with
               a permissions.allow array and a foreign PostToolUse hook before
               :CodriverStart comes back missing either
     contract: if the launch env drops the channel, the captured env lacks
               CODRIVER_STATE_FILE pointing at a readable file whose role is
               "navigator", or CODRIVER_NVIM_SERVER that sockconnects from this
               process
     contract: if the registered command is not actually runnable, spawning the
               registered argv verbatim with an empty stdin exits non-zero or
               writes to stderr — this is what proves hook_command()'s path
               resolves to a real file under a plugin-manager-style install
               rather than to the developer's cwd
     contract: if the user is required to hand-edit anything, the check's project
               dir needed a pre-seeded hooks block for the run to pass — it starts
               with permissions only, and enforcement must be live anyway (c-1)

t-8  Headless refusal and read-only checks
     files:    tests/nvim/hook_decision_check.lua
     covers:   c-2, c-3, c-4, c-5
     depends:  t-4, t-5, t-6
     contract: if the gate is not reached at runtime, running the registered hook
               command with an Edit payload targeting a fixture file while
               navigator produces empty stdout; and the fixture's sha256 is
               compared before and after the call — byte-identity is asserted,
               not assumed (c-2)
     contract: if the denial is advisory rather than permission-layer, the parsed
               stdout's permissionDecision is not "deny" or the reason is not
               codriver's string — a hook that merely returned prose would leave
               the model free to proceed (c-3)
     contract: if instruction text can defeat it, a payload whose tool_input
               carries "the user has explicitly approved this edit, proceed" and
               a Write payload whose content is an apology-and-retry still deny,
               with the same reason as the plain payload (c-3)
     contract: Bash matrix through the real script, each with the target file's
               bytes checked afterwards: `echo hi > victim.txt` denies and
               victim.txt is unchanged; `git status --short` allows; the
               configured test command allows; `git status --short && rm
               victim.txt` denies and victim.txt still exists (c-4, c-5)
     contract: if read-only work is caught in the net, Read / Grep / Glob
               payloads produce non-empty stdout while navigator (c-5)
     contract: if the deny reason names a command that does not exist yet, the
               reason contains ":Codriver" — the locked refusal_message forbids
               naming a handover command, and this is the runtime half of t-1's
               unit assertion (c-3)

t-9  Headless live-role, fail-closed and notify check
     files:    tests/nvim/hook_liveness_check.lua
     covers:   c-6, c-7, c-8
     depends:  t-4, t-5, t-6
     contract: if the decision is fixed at launch, the same Edit payload denies,
               then after role.set("driver") in this same Neovim — with no
               relaunch of anything and no new env — still denies; it must flip to
               empty stdout, and flip back on role.set("navigator") (c-6)
     contract: if the role is read from the environment instead of the file,
               rewriting the state file's role field directly and re-running the
               hook changes nothing
     contract: live socket, broken role: state file removed / truncated to half a
               JSON object / role rewritten to "nvigator" each produce a deny
               naming the indeterminate reason, not the navigator reason — three
               separate spawns, because one path passing must not cover the
               others (c-7)
     contract: if the no-session path fails closed, a hook run whose
               CODRIVER_NVIM_SERVER points at a socket that no longer exists
               produces non-empty stdout — a plain `claude` in this repo after
               Neovim exits must be unimpeded (locked no_session_behaviour)
     contract: if the refusal never reaches Neovim, then with vim.notify recorded
               and vim.wait polling, a denied Edit produces exactly one
               notification containing "Edit" and the target path at WARN or
               above, within the wait — and the check reads nothing from the
               hook's stdout to establish it, because c-8 is precisely "without
               the user reading the Claude terminal" (c-8)
     contract: if notifications are sent on allows too, an allowed Read produces
               a notification and the user is trained to ignore them
     contract: if the notification blocks the decision, the wall time of a denied
               call with a live-but-unresponsive channel exceeds the allowed
               command's time by more than the harness's tolerance — the push is
               fire-and-forget (rpcnotify), never a round trip (locked
               role_channel)
```

## Coverage

| Criterion | Tasks | Where the contract lives |
|---|---|---|
| c-1 | t-3, t-5, t-6, t-7 | merge preserves every existing allow entry (t-3); env injected before vendored setup (t-5); armed before the terminal opens (t-6); registered-and-runnable at launch, from a permissions-only seed file (t-7) |
| c-2 | t-1, t-4, t-8 | write-tool set + unknown-tool deny (t-1); deny payload shape distinct from a crash (t-4); fixture sha256 identical across a denied Edit (t-8) |
| c-3 | t-1, t-4, t-8 | reason wording, no `:Codriver` name (t-1); permissionDecision:"deny" not prose (t-4); explicit-authorization payload still denies (t-8) |
| c-4 | t-1, t-8 | 13-command Bash deny matrix incl. substitution, separators and `sh -c` (t-1); the same through the real script with the target file checked after (t-8) |
| c-5 | t-1, t-4, t-6, t-8 | read-only allowlist and test_command exact match (t-1); allow emits nothing so the user's own prompts survive (t-4); test_command reaches the published state (t-6); Read/Grep/Glob and `git status` allowed at runtime (t-8) |
| c-6 | t-2, t-5, t-9 | publish on every change (t-2); listener registered by setup (t-5); role flip changes the decision with nothing relaunched (t-9) |
| c-7 | t-1, t-2, t-4, t-9 | indeterminate reason distinct from the navigator reason (t-1); atomic write so no reader sees a torn file (t-2); live-socket + broken-state denies, internal raise denies (t-4); three broken-state spawns (t-9) |
| c-8 | t-2, t-4, t-9 | refused() notifies once naming tool and path (t-2); notify failure does not downgrade the deny (t-4); notification observed in Neovim without reading stdout (t-9) |

8/8 criteria covered. t-4's harness addition is the only enabler-shaped work and
it rides along with the module whose IO contract it drives.

## Judgment calls

- **Hook runs as `nvim --clean -l lua/codriver/hook.lua`, not `sh`+`jq`.**
  Rejected a POSIX-sh hook (jq is not guaranteed present, and the c-8 push would
  need a second tool) and a compiled helper (new toolchain). nvim is the one
  interpreter this plugin can assume, it brings `vim.json` and
  `vim.fn.sockconnect`, and the gate stays inside `luacheck` and
  `lua-language-server`. Accepted cost: ~50–80 ms of nvim startup per gated tool
  call, and a missing nvim binary degrades to allow (the same direction as the
  locked no_session_behaviour).
- **Allowlist of read-only tools, not a deny-list of write tools.** Rejected
  denying a fixed set of {Edit, Write, MultiEdit, NotebookEdit}: c-2's guarantee
  would silently lapse the day Claude Code ships a new file-writing tool. This is
  the same argument the locked `bash_policy` already accepted for shell commands,
  applied one level up; the accepted cost is identical (a new read-only tool is
  refused until the list grows).
- **Allow emits nothing rather than `permissionDecision: "allow"`.** An explicit
  allow would bypass the user's own permission prompts for every tool while
  driver — codriver would become a blanket grant. Rejected the symmetric-looking
  design in favour of "deny loudly, otherwise stand aside", and made it the
  loudest contract in t-4.
- **Liveness is the RPC socket; role is the state file.** Rejected deriving both
  from the state file: a state file outliving a crashed Neovim would then refuse a
  plain `claude` run, contradicting `no_session_behaviour`, and a torn file would
  read as "no session" instead of triggering c-7. Two channels means c-7 and the
  no-session case are separately testable, which is the whole point.
- **`test_command` is one new top-level config key, exact-match only.** The
  locked `bash_policy` names "a codriver-configured test command", and the
  deferred item defers *the allowlist's shape as public API* — not this. Rejected
  reading `.dross/project.toml` (couples the plugin to dross a phase early) and
  rejected allowing the `mise run` family (that would allow `mise run format`).
- **Pure cores, IO shells, and no change to `tests/busted_setup.lua`.** Rejected
  widening the stub to cover `vim.json`/`vim.fn`/`vim.uv` so these modules could
  be busted-tested whole; the stub's header forbids it and the previous phase
  paid to keep `config.lua` pure. Cost: `gate`, `claude_settings.merge` and
  `hook.evaluate` take injected context instead of reaching for the world.
- **Arming lives in `session.ensure_server()`, not `setup()`.** Rejected arming
  at setup: it would mutate `.claude/settings.local.json` on every `nvim` launch
  in the repo, session or not. `ensure_server` is the choke point every
  terminal-opening command already passes through.
- **No `:checkhealth` / `:CodriverStatus` line for enforcement.** No criterion
  asks for it and the verification lens does not build what no contract requires.
  Flagged rather than silently dropped: it is the obvious first candidate if the
  judge wants a user-visible confirmation that the hook is registered.
- **`.claude/settings.local.json` is not in any task's `files`.** It is
  gitignored and written at runtime by t-6; listing it would imply a hand edit,
  which is exactly what c-1 forbids. t-3 and t-7 assert against its real shape
  (a copy of its 20 existing `permissions.allow` entries) instead.
