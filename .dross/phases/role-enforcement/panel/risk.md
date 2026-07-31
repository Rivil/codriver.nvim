# risk lens — role-enforcement

Bias: **failure modes drive the graph.** Enforcement is a security boundary made
of five things that can each fail silently — a settings file that gets clobbered,
a state file that outlives its editor, a shell allowlist that gets out-parsed, a
hook process that crashes into an allow, and a notification path that hangs the
tool call. Each of those gets exactly one owner and one tripwire.

Two failure modes shape every decision below:

* **Fail-open is the default failure.** Claude Code treats a malformed hook
  payload, an unrecognised JSON shape, and exit code 1 all as *allow*. Every
  crash path inside a live session must be converted into a deny by the
  entrypoint, or enforcement evaporates exactly when something is wrong.
* **The refusal has to be sound by construction, not by enumeration.** A
  deny-list of tool names loses to the next tool Claude ships; a deny-list of
  shell commands loses to `eval`. Both surfaces are allowlists, and "unknown"
  means deny while a live navigator session is readable.

Phase role-enforcement — 12 tasks across 5 waves

## Wave 1

```
t-1  Session state file and liveness probe
     files:    lua/codriver/hook/state.lua
               tests/nvim/hook_state_check.lua
     covers:   c-6, c-7
     desc:     publish(role) / clear() / read(env) / probe(env) over a
               session-scoped JSON file outside the working tree. Owns the
               security-relevant "is a session live" question the
               no_session_behaviour lock creates.
     contract:
       - if the state path is frozen at module load instead of resolved per
         call, the check that redirects XDG_STATE_HOME/HOME into its sandbox and
         then requires the module finds the file written under the developer's
         real ~/.local/state — the same freeze-at-load trap the harness already
         guards for the vendored lockfile lock_dir
       - if the path lands inside the repo working tree, the check fails: it
         asserts path() is outside vim.fn.getcwd(), because a state file inside
         the tree is a role switch reachable from a tool call
       - if publish() is not atomic (temp file + rename), a reader sampling the
         file across 200 role flips observes a partial or empty document — every
         read must yield a valid role or ENOENT, never a half-written one; a
         stale <path>.tmp left by a killed writer must not block a publish
       - if probe() calls a session live purely because the file exists, then
         with the owning nvim killed probe returns live = true — a crashed editor
         would deny every write in that repo forever. Liveness is the owning
         process, not the file
       - if a corrupt or truncated file with the owning nvim still alive reports
         live = false, c-7 cannot fire: probe must return live = true, role = nil
         so the caller can fail closed, and that is a different result from "no
         session at all"
       - if the record drops its schema version or owner pid, a file written by a
         previous codriver version parses as a role rather than as unreadable,
         and a pid-recycled file reads as live
```

```
t-2  Read-only Bash allowlist matcher
     files:    lua/codriver/hook/bash.lua
               tests/codriver/hook_bash_spec.lua
     covers:   c-4, c-5
     desc:     Pure string matcher: normalize, reject anything that can
               introduce a second command or a redirection, then match each
               segment head against an allowlist with per-command argument
               rules. Allowlist is sound by construction (bash_policy lock).
     contract:
       - if redirection escapes, `echo hi > f`, `grep x lua/ >> out`, `cmd 2>f`
         and any use of `tee` are allowed — an unquoted >, >>, or a tee anywhere
         is a refusal even when the head token is allowlisted
       - if chaining escapes, `git status && rm -rf lua` is allowed — a command
         joined by &&, ||, ;, or a newline is refused unless every segment
         independently matches, and the spec asserts both halves of that rule
       - if substitution escapes, `grep "$(rm -f x)" .`, backtick substitution,
         and process substitution `<(...)` are allowed — refused regardless of
         head token, because the matcher cannot know what the inner command is
       - if an interpreter head slips through, `eval`, `sh -c`, `bash -c`,
         `xargs`, `env FOO=1 rm x`, `nohup` are allowed; likewise the write forms
         of otherwise-allowlisted heads — `find . -delete`, `find . -exec rm {}`,
         `sed -i`, `perl -i` — must be refused
       - if git is allowlisted by head rather than by subcommand, `git commit`,
         `git checkout .`, `git restore`, `git apply`, `git stash`, `git clean
         -fd`, `git config --global` are allowed; only status/log/diff/show/
         blame/ls-files/rev-parse pass
       - if the configured test command matches as a prefix rather than as a
         whole normalized command, `mise run test; rm x` and `mise run format`
         are allowed — `mise` is not an allowlisted head, the exact configured
         string is (the test command is a deliberate write-capable hole, so its
         match must be exact)
       - if head matching can be bypassed, `FOO=1 rm x` or `/bin/rm -rf .` are
         allowed — leading assignments are stripped before matching and an
         absolute path is matched on its basename
       - if the empty case falls through, `""` and `"   "` are allowed instead of
         refused
```

```
t-3  Write hook registration into settings.local.json
     files:    lua/codriver/hook/settings.lua
               tests/codriver/hook_settings_spec.lua
               tests/nvim/hook_settings_check.lua
     covers:   c-1
     desc:     `render(existing, command)` is a pure table transform;
               `install(path, command)` is the atomic read-merge-write around
               it. The real file already carries a 22-entry permissions.allow
               that must survive byte-identically.
     contract:
       - if render() does not preserve what it did not write, the existing
         permissions.allow array from the real .claude/settings.local.json is not
         reproduced element-for-element in order, or a sibling key (env, model)
         is dropped — codriver mutates a file in the user's working tree and gets
         exactly one chance to not destroy it
       - if registration is not idempotent, rendering twice yields two PreToolUse
         hook entries; and rendering over a settings file holding a codriver hook
         entry with an older (stale plugin-dir) command path appends a second
         instead of replacing it — a stale absolute path means silent no
         enforcement
       - if a foreign PreToolUse hook the user added is dropped or reordered,
         render fails: an unrelated matcher entry must survive untouched
       - if the matcher narrows to a list of write tools, a newly-named write
         tool is never hooked — the rendered entry's matcher must be `*`, which
         is what makes t-5's fail-closed default reachable at all
       - if install() is not atomic, the check that points it at a path whose
         rename target cannot be replaced finds the original truncated or gone;
         a half-written settings.local.json breaks every `claude` run in the repo
       - if a malformed existing settings.local.json is silently overwritten, the
         user's hand-written allow list is destroyed — install must refuse and
         report, leaving the file untouched
```

```
t-4  Neovim-side refusal notification receiver
     files:    lua/codriver/hook/notify.lua
               tests/codriver/hook_notify_spec.lua
     covers:   c-8
     desc:     The function the hook process reaches over RPC. Treats its
               argument as untrusted data from another process: no
               interpolation into executable text, no assumption of shape.
     contract:
       - if the payload is formatted rather than escaped, a tool name of
         "Edit\n%s%s" produces a multi-line notification or raises inside
         format() — one single-line notification, always
       - if the receiver trusts the arriving table, a payload with tool_name
         missing or non-string raises inside nvim's RPC handler instead of
         notifying an unknown-operation line; an error there is invisible to the
         user and the refusal goes unreported
       - if the message does not name the blocked operation, the notification for
         { tool = "Edit", path = "lua/x.lua" } lacks either "Edit" or
         "lua/x.lua" — c-8's whole point is knowing what was blocked without
         reading Claude's terminal
       - if the level drops to INFO, the refusal disappears under a user's
         vim.notify filter — asserted at WARN or above
       - if a refusal storm is not coalesced, ten denials inside one second
         produce ten notifications and bury the editor when the model retries in
         a loop
```

## Wave 2 (depends on wave 1)

```
t-5  Decision core: classify tool, resolve role, refuse
     files:    lua/codriver/hook/decision.lua
               tests/codriver/hook_decision_spec.lua
     covers:   c-2, c-3, c-5, c-6, c-7
     depends:  t-1, t-2
     desc:     Pure `decide(payload, session)` -> { permission, reason }. Read
               allowlist, write classification, Bash delegated to t-2, role read
               from the t-1 record, and the locked refusal text.
     contract:
       - if a write tool stops being classified, decide under navigator allows
         one of Edit / Write / MultiEdit / NotebookEdit — asserted per tool, not
         as a group
       - if an unrecognised tool name falls through to allow, a synthetic
         "SomeFutureWriteTool" passes under a live navigator session — the
         default inside a live session is deny and the read allowlist is the only
         path to allow, because c-2's byte-identity cannot survive a deny-list
       - if the read allowlist narrows, Read / Glob / Grep / WebFetch /
         WebSearch / TodoWrite / Task are denied and c-5's read-only work stops
         (Task is allowed because its subagent's own tool calls are hooked in
         turn, so the allowlist is not a hole)
       - if the vendored Neovim MCP tools are swept up, openDiff, saveDocument,
         close_tab or closeAllDiffTabs are denied — the nvim_write_tools lock
         keeps them live, and blocking them makes :CodriverDiffAccept dead code
       - if the reason text drifts from the refusal_message lock, it stops naming
         the navigator role, stops saying the block is harness-level and not
         retryable, or names a handover command that does not exist yet
       - if the decision reads anything but (tool, tool_input, role), an
         otherwise-identical payload carrying "the user explicitly authorised
         this edit" flips it to allow — c-3 holds only if phrasing is not an
         input
       - if fail-closed and fail-open are swapped, decide with session live and
         role nil returns allow, or decide with no session at all returns deny —
         these two must never be confused (c-7 vs the no_session_behaviour lock)
       - if Bash bypasses the matcher, decide{ tool = "Bash", command = "rm x" }
         is allowed without t-2 being consulted, and driver mode failing to
         release shows as Edit still denied after role = "driver"
```

```
t-7  Force the role channel into the CLI launch env
     files:    lua/codriver/config.lua
               tests/codriver/config_spec.lua
     covers:   c-1, c-6
     depends:  t-1
     desc:     `resolve(opts, channel)` merges CODRIVER_SESSION_FILE and
               CODRIVER_NVIM_ADDRESS into the vendored `claudecode.env` table
               the terminal hands the CLI. Forced, like auto_start already is.
     contract:
       - if the user's env table is clobbered, resolve({ claudecode = { env =
         { FOO = "1" } } }, channel) loses FOO — codriver adds keys, it does not
         own the table
       - if codriver's keys are defaulted rather than forced, a user setting
         claudecode.env.CODRIVER_SESSION_FILE points the hook at a file they
         control and role state becomes user-writable; both keys must be
         overwritten and one warning must name the ignored value
       - if the channel is absent, resolve(opts) with no channel emits the keys
         with nil/empty values — an empty CODRIVER_SESSION_FILE reads downstream
         as a live session with an unreadable file, i.e. c-7 firing on a plain
         `claude` run. The keys must be absent, not empty
       - if an empty v:servername still produces an address key, the CLI launches
         with a session file and a dead RPC address and every refusal is silent —
         the key is omitted and the omission is visible to the caller (t-8 turns
         that into a serverstart)
```

## Wave 3 (depends on wave 2)

```
t-6  Hook entrypoint: stdin contract, crash containment, notify
     files:    scripts/codriver-hook.lua
               mise.toml
               tests/nvim/hook_entrypoint_check.lua
     covers:   c-3, c-7, c-8
     depends:  t-1, t-4, t-5
     desc:     `nvim --clean -l scripts/codriver-hook.lua` — read stdin, decide,
               print the PreToolUse JSON, fire-and-forget the refusal over RPC.
               Every internal error inside a live session becomes a deny. mise.toml
               widens the syntax/lint globs to cover scripts/.
     contract:
       - if an internal error fails open, then with CODRIVER_SESSION_FILE set the
         script exits 0 with no deny for each of: unparsable stdin, valid JSON of
         the wrong shape, a state file replaced by a directory, and a decision
         module that raises — all four must emit a deny, asserted on stdout and
         exit status
       - if the emitted JSON drifts from the PreToolUse contract, stdout stops
         parsing as { hookSpecificOutput = { hookEventName = "PreToolUse",
         permissionDecision = "deny", permissionDecisionReason = <t-5's reason> } }
         — a shape Claude Code does not recognise is treated as allow, so the
         entire phase hangs on this one key name
       - if anything else reaches stdout, a stray print or an nvim startup message
         makes the document unparsable and the deny silently degrades to an allow
         — the check asserts stdout is exactly one JSON object
       - if package.path is not derived from the script's own path, running the
         script with cwd = / and no runtimepath cannot require
         codriver.hook.decision and every tool call fails open
       - if the notification send is blocking or unguarded, pointing
         CODRIVER_NVIM_ADDRESS at a dead socket path makes the script hang or exit
         non-zero instead of returning its deny inside the timeout — notification
         failure must never change the decision (c-8 must not be able to break c-2)
       - if an allowed call still notifies, an allowed Read against a live session
         sends an RPC message and the editor gets chattered at for normal work
       - if the entrypoint escapes CI, `mise run check` stops parsing
         scripts/codriver-hook.lua — today's globs are `find lua` and `luacheck
         lua/ tests/`, so a syntax error there disables enforcement with a green
         pipeline
```

## Wave 4 (depends on wave 3)

```
t-8  Wire enforcement into setup and session lifecycle
     files:    lua/codriver/hook/init.lua
               lua/codriver/init.lua
               tests/nvim/hook_install_check.lua
     covers:   c-1, c-6, c-8
     depends:  t-1, t-3, t-4, t-6, t-7
     desc:     setup() installs the hook registration, ensures an RPC address,
               publishes the role now and on every change, and clears the state
               file on VimLeavePre.
     contract:
       - if setup() does not install the registration, .claude/settings.local.json
         in the check's temp project has no PreToolUse entry after
         require("codriver").setup({}) and the user is back to hand-editing (c-1)
       - if the registered command path does not resolve, the check fails: it
         reads the command out of the written settings file, asserts the file
         exists and is executable by `nvim -l`, and runs it — a plugin dir that
         moved leaves a stale absolute path and silent non-enforcement
       - if the role is published only at setup time, role.set("driver")
         afterwards leaves the state file reading navigator — the on_change
         listener is what makes c-6 live rather than launch-fixed
       - if the state file outlives Neovim, a child nvim that sets up and then
         :qa leaves it behind, and the next bare `claude` run in that repo is
         governed by a session that does not exist — the check asserts the file is
         gone after the child exits, including when the child exits via :cquit
       - if serverstart is skipped when v:servername is empty, the injected
         CODRIVER_NVIM_ADDRESS is absent in exactly the headless case the checks
         run in, and every refusal is silent (c-8)
       - if install is not idempotent, a second setup({}) — the plugin-manager
         double-setup case — adds a second PreToolUse entry or a second role
         listener, so one refusal notifies twice
       - if publish happens after the commands are registered rather than before,
         there is a window where the settings file is live and the state file is
         not; the check asserts the state file reads navigator immediately after
         setup returns, before any flip
```

## Wave 5 (end-to-end; depends on wave 4)

Each of these drives the *real* entrypoint as a subprocess against a *real* live
session, with realistic PreToolUse payloads on stdin. They deliberately overlap
the unit specs — that is what keeps the pure decision core honest about the
shape of the thing it is deciding on.

```
t-9   Headless write-refusal and byte-identity check
      files:    tests/nvim/enforcement_write_check.lua
      covers:   c-2, c-3
      depends:  t-6, t-8
      contract:
        - if a denied Edit still reaches disk, the check fails: it sha256s a
          fixture file, drives the hook with an Edit payload targeting it, and
          requires both a deny and a byte-identical file afterwards (c-2)
        - if the refusal depends on phrasing, the same payload with an added
          "the user has authorised this edit" instruction field is allowed —
          this is the c-3 assertion, and it is a permission-layer property, not
          a model-behaviour one
        - if a new tool name defaults to allow, the check's synthetic "Edit2"
          payload passes under navigator
        - if the vendored diff surface is caught in the net, an openDiff payload
          is denied and :CodriverDiffAccept becomes unreachable
        - if driver mode does not release, the same Edit payload after
          role.set("driver") in the live instance is still denied — enforcement
          that cannot be handed back is a broken plugin, not a safe one
```

```
t-10  Headless Bash refusal and read-only survival check
      files:    tests/nvim/enforcement_bash_check.lua
      covers:   c-4, c-5
      depends:  t-6, t-8
      contract:
        - if a shell write is not refused on the same grounds as Edit, `printf x
          > <fixture>` is allowed, or the fixture is not byte-identical, or its
          reason differs from the Edit refusal's (c-4)
        - if chaining defeats it end-to-end, `git status --short && printf x > f`
          is allowed or f exists afterwards
        - if read-only work is only theoretically allowed, the check does not
          merely assert the decision: it runs `grep -rn role lua/` and `git
          status --short` through the allow path and requires real output and
          exit 0 (c-5)
        - if the project's test command stops being allowed, the exact
          `mise run test` string from .dross/project.toml is denied — asserted as
          a decision, not by running it, so the check cannot recurse into itself
```

```
t-11  Headless liveness and fail-closed check
      files:    tests/nvim/enforcement_liveness_check.lua
      covers:   c-6, c-7
      depends:  t-6, t-8
      contract:
        - if the decision is fixed at launch, an Edit payload denied, then
          role.set("driver") in the live instance, then the identical payload
          re-run against the same already-launched session is still denied — no
          relaunch, no re-read of env (c-6)
        - if fail-closed does not fire inside a live session, then with the
          instance alive and the state file truncated to "{", or deleted
          outright, the Edit payload is allowed (c-7) — both mutations asserted
        - if the no-session path fails closed, then with the instance killed, or
          with CODRIVER_* absent from the environment entirely, the same payload
          is denied — a plain `claude` in this repo must keep working, which is
          the whole no_session_behaviour lock
        - if a stale record is trusted, a state file whose owner pid is dead but
          whose contents say navigator denies the payload
```

```
t-12  Headless refusal-notification round-trip check
      files:    tests/nvim/enforcement_notify_check.lua
      covers:   c-8
      depends:  t-6, t-8
      contract:
        - if the refusal never reaches the editor, the check fails: it stubs
          vim.notify in the live instance, drives a denied Edit through the real
          hook subprocess, waits on the receiving side, and requires exactly one
          notification naming "Edit" and the target path (c-8)
        - if allowed work notifies, an allowed Read produces any notification
        - if delivery depends on the hook process still being alive, the message
          never lands — the check asserts arrival after the subprocess has
          already exited
        - if a dead RPC address turns a deny into something else, the check with
          CODRIVER_NVIM_ADDRESS pointed at a nonexistent socket sees anything but
          a clean deny with zero notifications
```

## Coverage

| criterion | tasks |
|---|---|
| c-1 launch applies codriver's permission config, no hand-editing | t-3, t-7, t-8 |
| c-2 file-editing tool refused before it runs, file byte-identical | t-5, t-9 |
| c-3 permission-layer denial with codriver's reason, prompt-independent | t-5, t-6, t-9 |
| c-4 shell write refused on the same grounds | t-2, t-10 |
| c-5 read, search and the test command still succeed | t-2, t-5, t-10 |
| c-6 decision reads live role state, not a launch-time value | t-1, t-5, t-7, t-8, t-11 |
| c-7 undeterminable role inside a live session refuses | t-1, t-5, t-6, t-11 |
| c-8 refusal raises a Neovim notification naming the operation | t-4, t-6, t-8, t-12 |

All 8 criteria covered; no task without a specific contract. t-1 through t-4 are
wave-1 parallel; t-5 and t-7 are the only wave-2 work and are independent of each
other; the four wave-5 checks are fully parallel.

## Judgment calls

- **Unknown tool names deny inside a live navigator session.** Rejected the
  gentler "deny a known write-tool list, allow the rest", because c-2 promises
  byte-identity and a deny-list loses to the next tool Claude ships. Cost: a new
  read-only tool is refused until added to the allowlist — the same accepted cost
  the bash_policy lock already takes for the shell, applied consistently.
- **`nvim --clean -l` as the hook interpreter, not sh + jq or python.** Neovim is
  already a hard dependency and brings JSON decode, filesystem and RPC in one
  binary; a shell hook would need jq (not guaranteed) and would parse JSON with
  string tools inside the very security boundary it implements. Cost: ~50–100 ms
  process startup per gated tool call. This is also why the role channel is a
  file rather than an RPC round-trip — the role_channel lock already paid for
  that, and the interpreter choice must not undo it.
- **Entrypoint at `scripts/codriver-hook.lua`, not `.claude/hooks/` or under
  `lua/`.** `.gitignore` un-ignores `.claude/hooks/`, but a per-project copy goes
  stale on plugin upgrade; a file under `lua/` is a module on runtimepath that
  would have to detect its own `-l` invocation. `scripts/` matches the existing
  `vendor-sync.sh` and costs one mise.toml glob widening so CI still parses it.
- **Split the decision core from the Bash matcher (t-5 / t-2) rather than one
  gate module.** They fail differently — one loses to an unmodelled tool name,
  the other to shell syntax — and a single module makes the shell test surface
  (a dozen bypass classes) unownable. Rejected merging them despite each being
  two files.
- **State file keyed to the owning process and stored outside the working
  tree.** Rejected a repo-local `.codriver/` file: an allowlisted read-only Bash
  command cannot write it, but a state file in the tree is one path-traversal
  bug from being a role switch, and it would show up in `git status` for every
  user of the repo.
- **`settings.install` refuses a malformed existing file instead of rewriting
  it.** Rejected "back it up and replace": codriver writing into the user's
  working tree is the accepted cost of the settings_delivery lock, and the way to
  keep that cost bounded is to never be the thing that deletes hand-written
  permissions. A loud refusal at setup is recoverable; a silent replacement is
  not.
- **Four separate wave-5 checks rather than one enforcement check.** They are
  four different tripwires (disk identity, shell, liveness, notification) and one
  file would make the first failure hide the other three, since harness
  assertions exit the process immediately.
- **c-3 is asserted structurally, not against a real Claude.** No headless check
  can prove a model did not choose to decline; what it can prove is that the deny
  is emitted by the permission layer for a payload whose only difference is an
  explicit authorisation instruction. Human verification against a real `claude`
  session remains the final word, exactly as the previous phase left the
  genuinely-connected status state human-checkable.
