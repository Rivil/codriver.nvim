# role-enforcement — panel synthesis

Judged cold: three decompositions of the same spec, none of them mine.

## Scores

| dimension | risk | mvp | verification |
|---|---|---|---|
| **criteria coverage** | 8/8, one task per criterion-owner, but c-1 is only ever proven against a script path the test composed itself — the *generated* registration is never the thing that enforces. | 8/8, but coarse: t-1 carries five criteria and t-4 carries seven, so "covered" and "owned" stop being the same claim. | 8/8 and the only draft whose coverage table names *where each contract lives* per criterion — the mapping is auditable rather than asserted. |
| **test-contract specificity** | Strongest overall: every contract is written as a concrete failure ("if X, then this exact input is allowed"), with the sharpest bash-bypass and settings-preservation matrices in the panel. | Good, and uniquely concrete about environmental hazards (PATH stripped, hook must not touch the workspace), but bundles several failure modes per bullet. | Nearly as sharp as risk, and holds the single highest-value assertion in the panel — *an allow must emit nothing* — which neither other draft states. |
| **granularity** | Best: one owner and one tripwire per failure mode; explicitly rejects merging the bash matcher into the decision core, which is the right call. | Weakest: `enforce.lua` owns state file + launch env + notify + read, and `policy.lua` owns the tool gate + the whole shell allowlist. Two modules absorb the phase's two largest test surfaces. | Middle: pure-core/IO-shell split is principled, but t-2 (`enforce.lua`) reunites state IO, address, notify and hook-command composition into one task. |
| **wave correctness** | 5 waves, every edge real (state → decision → entrypoint → wiring → e2e). Task numbering runs out of order across waves (t-7 before t-6), cosmetic only. | 3 waves, edges correct, but wave 1 hides a serial dependency: t-1's bash allowlist and t-1's tool gate are one task doing two independent things. | 3 waves, edges correct; one internal contradiction — t-2 does file IO, `serverstart` and `sockconnect` yet is specced under busted (`tests/codriver/enforce_spec.lua`), which its own stated stub rule forbids. |

**Skeleton: `risk`.** It is the only draft whose task boundaries follow the phase's actual failure modes rather than its module list, and enforcement is a security boundary where a merged task means an unownable test surface. Its contracts are also the most directly executable as written. It loses points on two things the runners-up fix, and both are grafted below: it never proves the *generated* registration enforces (verification t-7 / mvp t-6), and it arms enforcement at `setup()` where the other two put it on the session path.

---

## Merged plan

Phase role-enforcement — **14 tasks across 5 waves**

Constants adopted across all tasks (see Disagreements for the ones that were contested):
- Entrypoint: `scripts/codriver-hook.lua`, invoked `nvim --clean -l <plugin_root>/scripts/codriver-hook.lua`.
- Modules under `lua/codriver/hook/`.
- Launch channel: `CODRIVER_STATE_FILE` + `CODRIVER_NVIM_ADDRESS`.
- Registered matcher: `*`. Allow is silent (empty stdout, exit 0); only deny emits JSON.

### Wave 1 — four independent leaves

```
t-1  Session state file and liveness probe                       [risk] (+mvp, +verification)
     files:    lua/codriver/hook/state.lua
               tests/nvim/hook_state_check.lua
     covers:   c-6, c-7
     desc:     publish(role) / read(path) / probe(env) / clear() over a
               session-scoped JSON record at stdpath("state")/codriver/<pid>.json
               [mvp]. Owns the security-relevant "is a session live" question the
               no_session_behaviour lock creates.
     contract:
       - if the state path is frozen at module load instead of resolved per call,
         the check that redirects XDG_STATE_HOME/HOME into its sandbox finds the
         file under the developer's real ~/.local/state — the same freeze-at-load
         trap the harness already guards for the vendored lock_dir            [risk]
       - if the path lands inside the working tree, the check fails: path() is
         asserted outside vim.fn.getcwd(), because a state file in the tree is a
         role switch reachable from a tool call                               [risk]
       - if publish() is not temp-file-plus-rename, a reader sampling across 200
         role flips observes a partial document; asserted at the call level (the
         module must never open the final path for truncation), because a torn
         file read as "live, role unreadable" turns cosmetic non-atomicity into
         refused read-only work                            [risk + verification]
       - if read() collapses its failure modes, read(<missing>) and read(<"{not
         json">) return the same value — the caller allows on the first and denies
         on the second, so one result for both makes c-7 and
         no_session_behaviour indistinguishable                                [mvp]
       - if probe() calls a session live purely because the file exists, a killed
         nvim leaves probe live = true and every write in that repo is denied
         forever — liveness is the owning process, not the file                [risk]
       - if a corrupt file with the owning nvim alive reports live = false, c-7
         cannot fire: probe returns live = true, role = nil, which is a different
         result from "no session at all"                                       [risk]
       - if the record drops schema version or owner pid, a file from a previous
         codriver version parses as a role and a pid-recycled file reads as live [risk]
```

```
t-2  Read-only Bash allowlist matcher                    [risk] (+verification, +mvp)
     files:    lua/codriver/hook/bash.lua
               tests/codriver/hook_bash_spec.lua
     covers:   c-4, c-5
     desc:     Pure string matcher, no vim.* — refuse anything that can introduce
               a second command or a redirection, then match each segment head
               against an allowlist with per-command argument rules. Sound by
               construction (bash_policy lock).
     contract:
       - redirection: `echo hi > f`, `grep x lua/ >> out`, `cmd 2>f`, and any use
         of `tee` are refused even when the head token is allowlisted            [risk]
       - chaining: `git status && rm -rf lua`, `git log; rm x` refused unless every
         segment independently matches — and the inverse half is asserted too:
         `git log | head -20` must ALLOW, so segmenting is not quietly dropped
                                                                    [risk + mvp]
       - substitution: `grep "$(rm -f x)" .`, backticks, `<(...)` refused
         regardless of head token                                              [risk]
       - interpreters and write-forms: `eval`, `sh -c`, `bash -c`, `xargs`,
         `env A=1 rm x`, `nohup`, `python3 -c "open('f','w')"`, `find . -delete`,
         `find . -exec rm {}`, `sed -i`, `perl -i` each refused individually
                                                        [risk + mvp + verification]
       - git by subcommand, not by head: `git commit`, `git checkout .`,
         `git restore`, `git apply`, `git stash`, `git clean -fd`,
         `git config --global` refused; only status/log/diff/show/blame/ls-files/
         rev-parse pass                                                        [risk]
       - allow set asserted positively: `rg -n pat lua/`, `git status --short`,
         `git log --oneline -5`, `ls tests`, `cat README.md`  [verification + mvp]
       - test command matches the whole normalized command exactly, not a prefix:
         `mise run format` and `mise run test; rm x` are refused when
         test_command is `mise run test` — it is a deliberate write-capable hole
                                                        [risk + mvp + verification]
       - head bypasses: `FOO=1 rm x` (leading assignments stripped before
         matching), `/bin/rm -rf .` (absolute path matched on basename),
         `rgx --write f` (no prefix matching)                    [risk + verification]
       - `""` and `"   "` refuse rather than falling through                    [risk]
```

```
t-3  Merge codriver's hook into .claude/settings.local.json  [risk+mvp+verification]
     files:    lua/codriver/hook/claude_settings.lua
               tests/codriver/hook_claude_settings_spec.lua
               tests/nvim/hook_settings_check.lua
     covers:   c-1
     desc:     merge(existing, command) is a pure table transform (busted-testable);
               install(path, command) is the atomic read-merge-write around it
               (headless). Name from [verification] — `settings.lua` would collide
               with codriver's own config vocabulary.
     contract:
       - if merge() does not preserve what it did not write, the 20 existing
         permissions.allow entries of the repo's real settings.local.json are not
         reproduced element-for-element in order, or a sibling top-level key is
         dropped — NOTE: risk said 22 and verification said 18; the file holds 20
         today, so the contract must assert "all existing entries, in order", not
         a literal count                                     [risk + verification]
       - if registration is not idempotent, merging twice yields two codriver
         PreToolUse entries — asserted by count, not string equality  [verification]
       - if a stale entry is not replaced, merging with a new plugin root leaves the
         old command string alongside the new one; the match is on the entry whose
         command names codriver's hook script — a stale absolute path is silent
         non-enforcement                                       [risk + verification]
       - if third-party hooks are collateral damage, an unrelated PreToolUse matcher
         and a PostToolUse block present before the merge are absent after
                                                              [risk + verification]
       - if serialization is not deterministic (stable key order and indent),
         encoding an already-registered document twice produces different bytes —
         without byte-stability, "codriver re-registers on every start" becomes an
         unreviewable working-tree diff                                [verification]
       - if the matcher narrows to a list of write tools, a newly-named write tool
         is never hooked — the rendered matcher must be `*`                    [risk]
       - if install() is not atomic, pointing it at a path whose rename target
         cannot be replaced leaves the original truncated or gone               [risk]
       - if malformed existing JSON is silently overwritten, the user's hand-written
         allow list is destroyed — install must refuse, name the path, and leave the
         file untouched                                  [risk + mvp + verification]
       - if the target path drifts, install(<temp root>) writes anything under the
         repository's own .claude/ — every headless check runs with cwd at the repo
         root                                                                   [mvp]
```

```
t-4  Neovim-side refusal notification receiver               [risk] (+verification)
     files:    lua/codriver/hook/notify.lua
               tests/codriver/hook_notify_spec.lua
     covers:   c-8
     desc:     The function the hook process reaches over RPC. Treats its argument
               as untrusted data from another process. Busted-testable: vim.notify
               is the one API the existing stub already carries.
     contract:
       - if the payload is formatted rather than escaped, a tool name of
         "Edit\n%s%s" produces a multi-line notification or raises inside format()
         — one single-line notification, always                                [risk]
       - if the receiver trusts the arriving table, a payload with tool_name missing
         or non-string raises inside nvim's RPC handler instead of notifying an
         unknown-operation line — an error there is invisible and the refusal goes
         unreported                                                            [risk]
       - refused{tool="Edit", path="lua/x.lua"} emits exactly one vim.notify at
         WARN or above whose text contains both "Edit" and "lua/x.lua"
                                                        [risk + mvp + verification]
       - if it grows a return value or a blocking wait, the hook's fire-and-forget
         notify starts delaying every denied tool call                  [verification]
       - if a refusal storm is not coalesced, ten denials inside one second produce
         ten notifications and bury the editor when the model retries in a loop [risk]
```

### Wave 2 — depends on wave 1

```
t-5  Decision core: classify tool, resolve role, refuse    [risk] (+verification, +mvp)
     files:    lua/codriver/hook/decision.lua
               tests/codriver/hook_decision_spec.lua
     covers:   c-2, c-3, c-5, c-7
     depends:  t-1, t-2
     desc:     Pure decide(payload, session) -> { permission, reason }. Read
               allowlist, write classification, Bash delegated to t-2, role from
               t-1's record, and the locked refusal text. No vim.* — if it reaches
               for vim.fn/vim.uv/vim.json the spec errors on a nil field under the
               existing minimal stub rather than passing under a widened one
                                                                       [verification]
     contract:
       - if a write tool stops being classified, decide under navigator allows one
         of Edit / Write / MultiEdit / NotebookEdit — asserted per tool, not as a
         group                                                    [risk + verification]
       - if an unrecognised tool name falls through to allow, a synthetic
         "FutureWriteTool" passes under a live navigator session — the default
         inside a live session is deny, and the read allowlist is the only path to
         allow                                                    [risk + verification]
       - if the read allowlist narrows, Read / Glob / Grep / WebFetch / WebSearch /
         TodoWrite / Task are denied and c-5's read-only work stops (Task is allowed
         because its subagent's own calls are hooked in turn)      [risk + verification]
       - if the vendored Neovim MCP tools are swept up, openDiff, saveDocument,
         close_tab or closeAllDiffTabs are denied under their mcp__ prefix — the
         nvim_write_tools lock keeps them live, and blocking them makes
         :CodriverDiffAccept dead code                       [risk + mvp + verification]
       - if enforcement leaks past the role, decide{role="driver"} denies Edit,
         Write or `rm -rf build` — driver is unrestricted        [mvp + verification]
       - the refusal text contains "navigator", states the block is harness-level
         and not retryable, and a not-contains assertion on ":Codriver" pins that no
         handover command is named                           [risk + mvp + verification]
       - role nil, "", or "nvigator" inside a live session denies with the
         INDETERMINATE reason, asserted as a different string from the navigator
         reason — c-7's failure mode has to be readable in the refusal  [verification]
       - if the decision reads anything but (tool, tool_input, role), an otherwise
         identical payload carrying "the user explicitly authorised this edit" flips
         it to allow — c-3 holds only if phrasing is not an input              [risk]
       - if Bash bypasses the matcher, decide{tool="Bash", command="rm x"} is allowed
         without t-2 being consulted                                          [risk]
```

```
t-6  Launch channel + test_command option        [risk t-7 + mvp t-5 + verification t-6]
     files:    lua/codriver/config.lua
               tests/codriver/config_spec.lua
     covers:   c-1, c-6
     depends:  t-1
     desc:     resolve() merges CODRIVER_STATE_FILE and CODRIVER_NVIM_ADDRESS into
               the vendored claudecode.env table the terminal hands the CLI
               (forced, like auto_start already is), and accepts a new top-level
               codriver `test_command` key.
     contract:
       - if the user's env table is clobbered, resolve({claudecode={env={FOO="1"}}})
         loses FOO — codriver adds keys, it does not own the table              [risk]
       - if codriver's keys are defaulted rather than forced, a user setting
         CODRIVER_STATE_FILE points the hook at a file they control and role state
         becomes user-writable; both keys are overwritten with exactly one warning
         naming the ignored key                              [risk + mvp + verification]
       - if the channel is absent, resolve(opts) with no channel emits the keys with
         nil/empty values — an empty CODRIVER_STATE_FILE reads downstream as a live
         session with an unreadable file, i.e. c-7 firing on a plain `claude` run.
         The keys must be absent, not empty                                     [risk]
       - if every value is not a string, the vendored config.apply assert ("env
         values must be strings") fires — a pid injected as a number takes down
         setup()                                                       [verification]
       - if injection happens after the vendored setup rather than before, the
         variables never reach the CLI: the vendored init calls terminal.setup(...,
         config.env) during setup and freezes defaults.env there — assert the env
         table the fake receives, not a later mutation of it            [verification]
       - if the new option escapes validation, resolve({test_command=42}) returns
         instead of raising, resolve({test_commnd="x"}) stops being rejected as an
         unknown top-level key, or resolve({}).codriver.test_command is anything but
         nil; and test_command surfaces under .codriver, never under .claudecode
                                                              [mvp + verification]
```

### Wave 3 — depends on wave 2

```
t-7  Hook entrypoint: stdin contract, crash containment, notify
                                              [risk t-6] (+verification t-4, +mvp t-4)
     files:    scripts/codriver-hook.lua
               mise.toml
               tests/nvim/harness.lua
               tests/nvim/hook_entrypoint_check.lua
     covers:   c-2, c-3, c-5, c-6, c-7, c-8
     depends:  t-1, t-2, t-4, t-5
     desc:     `nvim --clean -l scripts/codriver-hook.lua` — read stdin, probe
               liveness, decide, emit only on deny, fire-and-forget the refusal over
               RPC. Every internal error inside a live session becomes a deny.
               mise.toml widens the syntax/lint globs to cover scripts/ (VERIFIED:
               today they are `find lua` and `luacheck lua/ tests/`, so a syntax
               error in scripts/ disables enforcement with a green pipeline) [risk].
               Adds harness.run_hook(payload, env) -> {code, stdout, stderr} driving
               the REGISTERED command, so t-10..t-14 cannot each grow a spawner and
               drift                                                    [verification]
     contract:
       - if an allowed tool emits an explicit allow, stdout is non-empty — it must
         be empty with exit 0. An emitted permissionDecision:"allow" auto-approves
         every tool the user never consented to, converting codriver from a
         restriction into a blanket permission grant. Highest-value assertion in the
         phase                                                          [verification]
       - if the deny payload drifts, stdout stops parsing as { hookSpecificOutput =
         { hookEventName = "PreToolUse", permissionDecision = "deny",
         permissionDecisionReason = <t-5's reason> } } — a shape Claude Code does
         not recognise is treated as allow                    [risk + verification]
       - if "the hook crashed" and "the hook denied" are the same observable, a bare
         non-zero exit is emitted instead of a deny document — a non-blocking hook
         error is allowed straight through                              [verification]
       - if an internal error fails open, then with a live session the script exits
         with no deny for each of: unparsable stdin, valid JSON of the wrong shape,
         a state file replaced by a directory, and a decision module that raises —
         all four asserted on stdout and exit status                            [risk]
       - if anything else reaches stdout, a stray print or an nvim startup message
         makes the document unparsable and the deny silently degrades to an allow —
         stdout is exactly one JSON object or empty                             [risk]
       - if the script loads user configuration, a temporary XDG_CONFIG_HOME/nvim/
         init.lua planted by the harness runs during the hook — a user's config can
         take seconds or prompt, on every gated tool call               [verification]
       - if package.path is not derived from the script's own path, running with
         cwd = / and no runtimepath cannot require the decision module and every
         tool call fails open                                                  [risk]
       - if the script grows a toolchain dependency, running it with PATH stripped to
         the directory holding `nvim` fails — it runs under --clean with no mise and
         no luarocks                                                            [mvp]
       - if the notification send is blocking or unguarded, pointing
         CODRIVER_NVIM_ADDRESS at a dead socket makes the script hang or exit
         non-zero instead of returning its deny — notification failure must never
         change the decision (c-8 must not be able to break c-2) [risk + verification]
       - if an allowed call still notifies, an allowed Read against a live session
         chatters at the editor during normal work                              [risk]
       - if the hook itself touches the workspace, the Edit payload's target file
         changes size or content across the run — the hook is a decision, not an
         actor                                                                  [mvp]
```

### Wave 4 — depends on wave 3

```
t-8  setup(): publish role, listen for changes, clean up on exit
                                                 [risk t-8 (setup half) + verification t-5]
     files:    lua/codriver/init.lua
               tests/nvim/hook_publish_check.lua
     covers:   c-6
     depends:  t-1, t-6
     desc:     setup() ensures an RPC address (serverstart when v:servername is
               empty), publishes the role immediately, re-publishes from a
               role.on_change listener, and clears the state file on the existing
               CodriverShutdown augroup.
     contract:
       - if the role is published only at setup time, role.set("driver") afterwards
         leaves the state file reading navigator — the on_change listener is what
         makes c-6 live rather than launch-fixed              [risk + mvp + verification]
       - if the state file outlives Neovim, a child nvim that sets up and :qa leaves
         it behind and the next bare `claude` run in that repo is governed by a
         session that does not exist — asserted for :qa AND :cquit  [risk + mvp]
       - if serverstart is skipped when v:servername is empty, CODRIVER_NVIM_ADDRESS
         is absent in exactly the headless case the checks run in and every refusal
         is silent                                            [risk + verification]
       - if setup is not re-entrant, a second setup({}) registers a second role
         listener and one refusal notifies twice              [risk + mvp + verification]
       - if publish happens after the commands are registered rather than before,
         there is a window where commands are live and the state file is not — the
         check asserts the state file reads navigator immediately after setup returns
                                                                                [risk]
```

```
t-9  Arm on session start, disarm on stop      [verification t-6 + mvp t-5] (+risk t-8)
     files:    lua/codriver/session.lua
               tests/codriver/session_spec.lua
               tests/nvim/hook_install_check.lua
     covers:   c-1
     depends:  t-3, t-6, t-8
     desc:     session.ensure_server() installs the settings registration before the
               terminal opens; stop() removes the state file. The settings entry
               deliberately survives stop (inert without a state file, per the
               settings_delivery cost).
     contract:
       - if arming happens after the terminal, the recorded call order from
         session.start() is open-then-write — the CLI can be issuing tool calls
         against a settings file with no hook in it yet. Ordering is the contract,
         exactly as it already is for the server/terminal pair          [verification]
       - if the already_running path skips arming, deleting settings.local.json and
         running ensure_server() again leaves it unregistered — every :Codriver*
         preflight goes through ensure_server, so that is the one place arming is
         guaranteed                                                     [verification]
       - if the settings file is written to vim.fn.getcwd() while the vendored
         terminal launches Claude at the git root, Claude never reads it — assert the
         write path is the directory the vendored cwd resolution hands the terminal
                                                                        [verification]
       - if the registered command path does not resolve, read the command back out
         of the written settings file, assert it exists and is executable by
         `nvim -l`, and run it — a moved plugin dir leaves a stale absolute path and
         silent non-enforcement                                                [risk]
       - if install is not idempotent, a start/stop/start cycle leaves two codriver
         PreToolUse entries                                          [mvp + risk]
       - if stop does not disarm, the state file survives session.stop() and a plain
         `claude` in this repo is refused with no Neovim behind it       [verification]
```

### Wave 5 — end-to-end, five parallel checks

Each drives the *real* entrypoint as a subprocess (via `harness.run_hook`) against a
*real* live session. They deliberately overlap the unit specs — that is what keeps
the pure cores honest about the shape of the thing they decide on. [risk]

```
t-10  Headless launch-time enforcement check            [verification t-7 + mvp t-6]
      files:    tests/nvim/enforcement_launch_check.lua
      covers:   c-1
      depends:  t-7, t-9
      desc:     The only check where the GENERATED registration is what enforces —
                every other check invokes the script by a path it composed itself.
      contract:
        - if registration is not in place when the CLI launches, the capture terminal
          provider's open is called while <project>/.claude/settings.local.json holds
          no codriver PreToolUse entry; each recorded provider call carries whether
          the file was armed at that moment, so late arming cannot be masked by a
          later read                                                    [verification]
        - if the pre-existing file is destroyed, a settings file seeded with a
          permissions.allow array and a foreign PostToolUse hook before
          :CodriverStart comes back missing either                      [verification]
        - if the launch env drops the channel, the captured env lacks
          CODRIVER_STATE_FILE pointing at a readable file whose role is "navigator",
          or CODRIVER_NVIM_ADDRESS that sockconnects from this process   [verification]
        - if the generated registration is not what enforces, the command string read
          out of the generated settings.local.json fails to produce a deny for an
          Edit payload while navigator                                    [mvp]
        - if the user is required to hand-edit anything, the check's project dir
          needed a pre-seeded hooks block to pass — it starts with permissions only,
          and enforcement must be live anyway                            [verification]
```

```
t-11  Headless write-refusal and byte-identity check       [risk t-9] (+verification t-8)
      files:    tests/nvim/enforcement_write_check.lua
      covers:   c-2, c-3
      depends:  t-7, t-9
      contract:
        - if a denied Edit still reaches disk, sha256 a fixture, drive the hook with
          an Edit payload targeting it, require both a deny and a byte-identical file
                                                              [risk + verification]
        - if the refusal depends on phrasing, the same payload with "the user has
          explicitly approved this edit, proceed" added to tool_input is allowed, or
          returns a different reason than the plain payload — this is c-3, and it is
          a permission-layer property, not a model-behaviour one  [risk + verification]
        - if the deny reason names a command that does not exist yet, the reason
          contains ":Codriver" — the runtime half of t-5's unit assertion [verification]
        - if a new tool name defaults to allow, a synthetic "Edit2" payload passes
          under navigator                                                    [risk]
        - if the vendored diff surface is caught in the net, an openDiff payload is
          denied and :CodriverDiffAccept becomes unreachable                 [risk]
        - if driver mode does not release, the same Edit payload after
          role.set("driver") is still denied — enforcement that cannot be handed back
          is a broken plugin, not a safe one                                 [risk]
```

```
t-12  Headless Bash refusal and read-only survival check     [risk t-10] (+verification)
      files:    tests/nvim/enforcement_bash_check.lua
      covers:   c-4, c-5
      depends:  t-7, t-9
      contract:
        - if a shell write is not refused on the same grounds as Edit, `printf x >
          <fixture>` is allowed, or the fixture is not byte-identical after, or its
          reason differs from the Edit refusal's                    [risk + verification]
        - if chaining defeats it end-to-end, `git status --short && rm victim.txt`
          is allowed or victim.txt is gone afterwards               [risk + verification]
        - if read-only work is only theoretically allowed, the check does not merely
          assert the decision: it runs `grep -rn role lua/` and `git status --short`
          through the allow path and requires real output and exit 0        [risk]
        - if read-only TOOLS are caught in the net, Read / Grep / Glob payloads
          produce a deny while navigator                                [verification]
        - if the project's test command stops being allowed, the configured
          test_command is denied — asserted as a decision, not by running it, so the
          check cannot recurse into itself                                  [risk]
```

```
t-13  Headless liveness and fail-closed check              [risk t-11] (+verification t-9)
      files:    tests/nvim/enforcement_liveness_check.lua
      covers:   c-6, c-7
      depends:  t-7, t-9
      contract:
        - if the decision is fixed at launch, an Edit payload denies, then
          role.set("driver") in the live instance, then the identical payload re-run
          against the same already-launched session still denies — no relaunch, no
          re-read of env; and it flips back on role.set("navigator")  [risk + verification]
        - if the role is read from the environment instead of the file, rewriting the
          state file's role field directly and re-running changes nothing [verification]
        - if fail-closed does not fire inside a live session, then with the instance
          alive and the state file (a) removed, (b) truncated mid-JSON, (c) role
          rewritten to "nvigator", the Edit payload is allowed — three separate
          spawns, each asserted to carry the indeterminate reason and NOT the
          navigator reason                                          [risk + verification]
        - if the no-session path fails closed, then with the instance killed, or with
          CODRIVER_* absent from the environment entirely, the same payload is denied
          — a plain `claude` in this repo must keep working    [risk + mvp + verification]
        - if a stale record is trusted, a state file whose owner pid is dead but whose
          contents say navigator denies the payload                          [risk]
```

```
t-14  Headless refusal-notification round-trip check       [risk t-12] (+verification t-9)
      files:    tests/nvim/enforcement_notify_check.lua
      covers:   c-8
      depends:  t-7, t-9
      contract:
        - if the refusal never reaches the editor, stub vim.notify in the live
          instance, drive a denied Edit through the real hook subprocess, poll with
          vim.wait, and require exactly one notification at WARN or above naming
          "Edit" and the target path — established without reading the hook's stdout,
          because c-8 is precisely "without the user reading the Claude terminal"
                                                              [risk + verification]
        - if allowed work notifies, an allowed Read produces any notification
                                                              [risk + verification]
        - if delivery depends on the hook process still being alive, the message never
          lands — arrival is asserted after the subprocess has exited          [risk]
        - if the notification blocks the decision, the wall time of a denied call with
          a live-but-unresponsive channel exceeds the allowed command's by more than
          the harness tolerance — the push is rpcnotify, never a round trip
                                                                        [verification]
        - if a dead RPC address turns a deny into something else, CODRIVER_NVIM_ADDRESS
          pointed at a nonexistent socket yields anything but a clean deny with zero
          notifications                                                       [risk]
```

### Coverage

| criterion | tasks |
|---|---|
| c-1 launch applies codriver's config, no hand-editing | t-3, t-6, t-9, t-10 |
| c-2 edit refused before it runs, file byte-identical | t-5, t-7, t-11 |
| c-3 permission-layer denial, prompt-independent | t-5, t-7, t-11 |
| c-4 shell write refused on the same grounds | t-2, t-12 |
| c-5 read, search and the test command still succeed | t-2, t-5, t-7, t-12 |
| c-6 decision reads live role, not a launch-time value | t-1, t-6, t-7, t-8, t-13 |
| c-7 undeterminable role inside a live session refuses | t-1, t-5, t-7, t-13 |
| c-8 refusal raises a Neovim notification | t-4, t-7, t-14 |

8/8 covered; every task carries at least one criterion and a specific contract.

---

## Disagreements

**1. An allow: silent, or an explicit `permissionDecision: "allow"`?**
- verification: emitting an explicit allow would bypass the user's own permission
  prompts for every tool — codriver becomes a blanket permission GRANT rather than a
  restriction. Allow must be empty stdout, exit 0. Calls it the phase's
  highest-value assertion.
- risk and mvp: both write contracts around an allow verdict being emitted as JSON
  (risk's t-6 asserts "stdout is exactly one JSON object"; mvp's t-4 asserts
  `"allow"` verdicts through the CLI).
- **Provisional default: silent allow.** Adopted into t-7's first contract, and
  risk's stdout contract restated as "exactly one JSON object *or empty*".
- Why it matters: this is the one divergence where a runner-up caught a defect that
  would ship as a *widening* of the user's permission surface — the opposite of the
  phase's purpose — and it is invisible to every other contract in all three drafts.

**2. Hook matcher: `*`, or the named write tools?**
- risk: matcher must be `*`, because that is the only thing that makes the
  fail-closed default for an unknown tool name reachable at all. verification agrees
  at the decision layer (a synthetic "FutureWriteTool" must deny).
- mvp: matcher `Edit|Write|MultiEdit|NotebookEdit|Bash`, to keep a ~60ms nvim start
  off every Read and Grep — "most of c-5's felt behaviour". mvp explicitly flags this
  for the judge as a one-string change.
- **Provisional default: `*`.** With silent-allow (divergence 1) the cost is bounded
  to latency, and c-2 promises byte-identity, which a deny-list cannot deliver.
- Why it matters: mvp's version is strictly faster and strictly less sound; it is the
  cheapest thing in the plan to reverse if the latency proves intolerable in real use,
  and reversing it silently voids the unknown-tool contract in t-5.

**3. What proves a session is live: the owning pid, or the RPC socket?**
- risk + mvp: state file present and its `pid` alive (`kill(pid,0)`). Keeps the hot
  path off a round trip, per the locked `role_channel`.
- verification: the socket is the liveness channel and the file is only the role
  channel — conflating them means a stale file from a crashed Neovim refuses a plain
  `claude` run, and a torn file reads as "no session" instead of triggering c-7.
- **Provisional default: pid liveness** (2-1, and it is the cheaper sound answer),
  with verification's concern absorbed as t-1's explicit three-way probe result:
  no session / live-but-role-unreadable / live-with-role.
- Why it matters: it decides whether c-7 and `no_session_behaviour` are separately
  testable. The pid design only stays safe because t-1's probe returns three states
  rather than two — if that collapses to a boolean during execution, verification's
  objection becomes correct retroactively.

**4. Module layout: `lua/codriver/hook/` subtree, or flat modules?**
- risk: five modules under `lua/codriver/hook/`.
- mvp + verification: flat (`policy`/`enforce`/`settings`, or
  `gate`/`enforce`/`claude_settings`/`hook`) — "three modules do not need a namespace".
- **Provisional default: the subtree.** mvp's flatness argument is priced for three
  modules; the merged plan keeps risk's five-way split, and five enforcement modules
  sitting beside the seven existing top-level ones is the worse read. mvp's specific
  objection (a `hook.lua` file coexisting with a `hook/` directory) does not apply,
  because the entrypoint is not under `lua/`.
- Why it matters: it is cosmetic on its own, but it is downstream of divergence 6
  (the module count). If the granularity is later collapsed to three modules, flat
  becomes the right answer again.

**5. Entrypoint location: `scripts/codriver-hook.lua` or `lua/codriver/hook.lua`?**
- risk + mvp: `scripts/`, matching the existing `vendor-sync.sh`.
- verification: under `lua/`, so it stays inside the existing `luacheck` and
  `lua-language-server` globs — a `sh`+`jq` hook would not be, and neither is
  `scripts/`.
- **Provisional default: `scripts/codriver-hook.lua`, plus the mise.toml glob
  widening risk specified.** I verified verification's premise is real: `mise run
  check` today runs `find lua …` and `luacheck lua/ tests/`, so `scripts/` is
  genuinely unchecked. risk is the only draft that noticed and paid for it; mvp put
  the script in `scripts/` and did not.
- Why it matters: without the mise.toml edit, a syntax error in the entrypoint
  disables enforcement with a green pipeline. If t-7's mise.toml change is dropped
  during execution, verification's placement becomes the safer plan.

**6. Where enforcement is armed: `setup()` or the session path?**
- risk: `setup()` installs the registration.
- mvp + verification: on session start (`session.ensure_server()`), because c-1 is
  about *starting a session*, and arming at setup writes `.claude/` into every repo
  the user opens Neovim in.
- **Provisional default: `session.ensure_server()`** (2-1, and the stronger
  argument). This is why the merged plan splits risk's single t-8 into t-8 (setup
  publishes role) and t-9 (session arms/disarms) — different files, different
  criteria.
- Why it matters: risk's version makes the plugin mutate a working tree in repos
  where the user never asked for Claude at all — a real user-visible cost that the
  `settings_delivery` lock accepted only for sessions.

**7. One end-to-end check, three, four — or five?**
- mvp: one (t-6), on the grounds that it is the only place registration, live role
  and byte-identity meet.
- verification: three (launch / decision / liveness+notify).
- risk: four (write, bash, liveness, notify) — one file per tripwire, because harness
  assertions exit the process immediately and one file would let the first failure
  hide the other three.
- **Provisional default: five** — risk's four plus verification's launch check, which
  risk lacks entirely and which is the only place the *generated* registration is what
  enforces.
- Why it matters: this is the largest single driver of the task count (14 vs 6). If
  the phase is judged too heavy, collapsing t-11..t-14 into two files is the cheapest
  reduction that does not lose an assertion — collapsing to mvp's single file does.

**8. One refusal reason, or two?**
- verification: the navigator refusal and the indeterminate (c-7) refusal must be
  distinguishable strings, asserted both in the unit spec and at runtime — c-7's
  failure mode has to be readable in the refusal the user sees.
- risk + mvp: a single locked refusal text; c-7 is asserted as a deny verdict, not as
  a distinct reason.
- **Provisional default: two distinguishable reasons**, both satisfying the
  `refusal_message` lock (name the navigator role, harness-level, not retryable, no
  handover command).
- Why it matters: with one string, a c-7 fail-closed deny is indistinguishable from
  normal navigator enforcement, and the user has no way to learn their role state
  went unreadable — which is exactly the condition worth surfacing.

**9. Where the test command comes from.**
- mvp + verification: a new top-level codriver config key `test_command`, defaulting
  to nil, matched byte-for-byte. verification explicitly rejects reading
  `.dross/project.toml` as coupling the plugin to dross a phase early.
- risk: t-10's contract asserts "the exact `mise run test` string from
  .dross/project.toml", implying the plugin reads dross's config.
- **Provisional default: the config key.** The deferred item defers the allowlist's
  *shape as public API*, not this one key; the checks pass their own configured value
  rather than reading `.dross/`.
- Why it matters: risk's reading would make a Neovim plugin depend on a dross file
  layout, and would silently allow nothing for any user not running dross.

**10. Where the state/IO module is tested.**
- mvp + risk: headless (`tests/nvim/`), because the module touches `vim.json`,
  `vim.fn` and `vim.uv`, which `tests/busted_setup.lua` deliberately does not carry.
- verification: `tests/codriver/enforce_spec.lua` — a busted spec — despite that same
  draft stating the stub must not grow into a vim mock. Internal contradiction.
- **Provisional default: headless for state IO (t-1), busted for the pure cores
  (t-2, t-5) and the notify receiver (t-4, which uses only `vim.notify` — already in
  the stub).**
- Why it matters: taking verification's placement literally would force the exact
  widening of `busted_setup.lua` that all three drafts agree is forbidden.

### Factual corrections carried into the merged plan

- `.claude/settings.local.json` holds **20** `permissions.allow` entries today —
  risk wrote 22, verification wrote 18. t-3's contract is therefore written as
  "every existing entry, in order", not against a literal count.
- `mise run check` really does glob only `lua/` and `tests/` (verified in
  `mise.toml`), which makes risk's mise.toml widening load-bearing rather than
  incidental.
