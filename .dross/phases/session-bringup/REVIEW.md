# Plan Review — session-bringup

Reviewed: 2026-07-30 (re-review, round 2)
Plan: 13 tasks across 4 waves

## BLOCKING

(none)

Coverage is complete and now multi-owned: c-1 (t-5, t-6, t-8), c-2 (t-5, t-6, t-9),
c-3 (t-2, t-5, t-10), c-4 (t-4, t-7, t-11), c-5 (t-5, t-8), c-6 (t-3, t-6, t-12),
c-7 (t-3, t-6, t-13), c-8 (t-2, t-6, t-8). No task contradicts a locked decision:
`auto_start` is forced false in t-2 with the opt-in kept on the codriver side of the
boundary (`session_start`), only `:Codriver*` names reach the user (`command_surface`),
the top-level/nested split is asserted directly (`options_shape`), the two status
surfaces are separated across t-4/t-7 (`status_surface`), and t-2 pins
`terminal.provider = "auto"` while t-9 exercises the nested override rather than
replacing the default (`terminal_provider`). No task lists a file under
`lua/codriver/vendor/` (r-02); none invokes `dross project set` (r-01). No global
rules file exists at `/Users/rivil/.claude/dross/rules.toml`.

## FLAG

- [test-contract] t-1's first three contract items cannot all hold. Item 1 fixes discovery
  as `tests/nvim/*_check.lua`; item 2 requires the discovered set to contain the
  pre-existing `tests/nvim/vendor_smoke.lua` ("losing it is a coverage regression, not a
  rename", and t-1's `files` does not include it, so it keeps its name); item 3 has the
  runner assert every discovered headless file ends in `_check.lua`. `vendor_smoke.lua`
  matches neither the glob nor the suffix. Under item 1's glob, item 3 is also tautological
  — for it to be able to fail, discovery must be `tests/nvim/*.lua` and then filter, at
  which point `harness.lua` and `vendor_smoke.lua` both trip it. t-1 is the enabler every
  other task depends on; the implementer has to invent this resolution.
  Suggestion: pick one and say it — either rename to `vendor_smoke_check.lua` (add it to
  t-1's `files`), or make discovery `tests/nvim/*.lua` with an explicit non-check allowlist
  (`harness.lua`, `vendor_smoke.lua`) and scope item 3's suffix assertion to the remainder.

- [granularity] t-1's last item ("if a red check file is added but not discovered, the
  discovered-count assertion fails") puts a maintenance point in `mise.toml`, which only
  t-1 owns — yet t-7, t-8, t-9, t-10, t-11, t-12 and t-13 each add one or more
  `*_check.lua` files and none of them lists `mise.toml` in `files`. If the count is
  hardcoded, six wave-3 tasks plus t-11 all have to edit the same line in a file outside
  their declared surface; if it is derived from the glob, the assertion cannot catch what
  it claims to.
  Suggestion: state the mechanism. Either add `mise.toml` to the `files` of every task
  that adds a check (and accept the contention), or replace the count with a committed
  manifest the harness diffs against, owned by t-1 and appended per task.

- [test-contract] t-5's seventh item ("session.start() on a fake no longer calls
  selection.enable") makes the wrapper arm selection tracking itself, which duplicates
  vendored `M.start` (`lua/codriver/vendor/claudecode/init.lua:547-550` already calls
  `selection.enable` when `config.track_selection`) and contradicts t-2's fourth item,
  which permits `claudecode = { track_selection = false }` with a warning. If the wrapper
  arms unconditionally, that option becomes inert and the warning is false. Worse, it
  leaks: vendored `M.stop` gates `selection.disable()` on `config.track_selection`
  (init.lua:576-579), so with the option off the wrapper creates the `ClaudeCodeSelection`
  autocmds and nothing ever clears them — they survive `:CodriverStop` pointing at a dead
  server. t-8's "non-empty after stop" item only runs under the default, so it will not
  catch this.
  Suggestion: either drop the wrapper-side call (c-3's ownership then rests on t-2's
  `track_selection` default, which is where the plan already puts it) and re-point the item
  at asserting `session.start` forwards a config with `track_selection` true; or make the
  wrapper's arming conditional on the resolved option and say so.

- [test-contract] t-12's fourth item is still unfalsifiable after the amendment, and the
  amendment's stated reason is wrong. `:checkhealth codriver` resolves by globbing
  runtimepath for `lua/**/codriver/health.lua` (`$VIMRUNTIME/lua/vim/health.lua:166-174`)
  — the *directory* name is the key. The fixture's new `lua/claudecode/health.lua` can
  never match that pattern, so "the fixture ships one precisely so this assertion can
  fail" does not hold. Verified in nvim 0.12.3 against this repo's runtimepath:
  `lua/**/codriver/health.lua` → no match today (t-7 creates it);
  `lua/**/claudecode/health.lua` → matches the vendored file. Round 1's vague clause has
  become a vacuous clause plus a fixture file justifying it, which is harder to notice
  later.
  Suggestion: drop the clause (t-7's fourth item already covers that
  `:checkhealth codriver` resolves codriver's module) and keep the fixture's `health.lua`
  only if it is repurposed for the finding below.

- [coverage] The health collision that is real runs the other way and no task asserts it.
  `:checkhealth claudecode` globs `lua/**/claudecode/health.lua`, which matches
  `lua/codriver/vendor/claudecode/health.lua` — confirmed by running the glob in nvim
  0.12.3 with this repo on runtimepath. So installing codriver injects a section into the
  rival plugin's health report (and bare `:checkhealth` gains a spurious
  `codriver.vendor.claudecode` section). c-6's text is about modules and user commands, so
  this is arguably out of scope — but t-12 already spends an assertion and a fixture file
  on checkhealth resolution, and this is the direction where something actually breaks.
  Suggestion: if it is in scope, add an item to t-12 that `:checkhealth claudecode` with
  the fixture loaded resolves the fixture's `health.lua` and not the vendored copy; if it
  is out of scope, record it as a deferred idea in spec.toml so it is a decision rather
  than an oversight.

- [antipattern] The phase-start version bump collides with a hardcoded assertion in a file
  t-6 owns. `tests/codriver/init_spec.lua:14` asserts
  `assert.are.equal("0.1.0", codriver.version:string())` against
  `M.version = { major = 0, minor = 1, patch = 0 }` in `lua/codriver/init.lua`, and
  `.dross/project.toml` currently reads `version = "0.1.0.0"`. Per the global versioning
  rule the phase bump makes that `0.1.1.0`. Neither t-6's description nor any contract item
  mentions the `M.version` table, so whether the Lua version follows the dross version is
  undecided — and if it does, t-6's spec goes red for a reason unrelated to t-6's work.
  Suggestion: state in t-6 whether `M.version` tracks the dross phase version. If it does,
  add `lua/codriver/init.lua`'s version table to the task and make the spec assertion read
  the table rather than a literal.

## NOTE

- [wave-order] t-7 lists t-4 in `depends_on`, but its description builds the report from
  `session.snapshot()` and never mentions `status.describe`. Costs no parallelism (t-6
  pins t-7 to wave 3 regardless), so it is at worst a stale edge. Every other dependency
  in the plan is output-level and strictly needed — t-11 → t-7 in particular is correct,
  since it drives `:checkhealth codriver`.

- [test-contract] Five of the fifteen vendored commands (`ClaudeCode`, `Focus`, `Open`,
  `Close`, `SendText`) are registered inside `if terminal_ok then` after a
  `pcall(require, "codriver.vendor.claudecode.terminal")` (init.lua:1074-1075). t-3's
  "map has 15 keys" and t-13's "every map value present in `nvim_get_commands`" both
  assume that require succeeds — it does for an intact vendored tree, so this is not a
  live risk, but a broken vendor-sync will surface as a confusing t-13 failure rather than
  as the require error it is. t-1's `vendor_smoke.lua` dependency is what actually guards
  it.

- [test-contract] t-6 injects a fake vendor into `package.loaded` in the same spec file
  that already asserts `package.loaded["codriver.vendor.claudecode"]` is nil after
  `require("codriver")`, and t-6's eighth item preserves that assertion. busted's
  declaration order protects it today (the nil check is declared first, and the mise task
  does not pass `--shuffle`), so no action is needed — but no contract item requires
  restoring `package.loaded`, so the file is order-dependent by construction.

- [strengths] All nine round-1 flags were genuinely acted on, not acknowledged and
  restated. Seven are cleanly closed, and the two strongest amendments went further than
  the suggestion: the `ensure_server()` / `start()` split is a better fix for the
  double-open than "say which one the guard calls", and it is now pinned from three
  independent angles (t-5's zero-terminal-open assertion, t-6's guard item, t-9's
  exactly-one-open-from-cold item).

- [strengths] t-5's sixth item closes the c-4 hole precisely and names why it is the one
  that matters: `client_count = 1` with `clients = {}` is the exact input where vendored
  `is_claude_connected` falls back to `client_count > 0` (init.lua:55-64), and the item
  states outright that this is the one path no other task leaves unstubbed. Deliberately
  identifying which assertion is load-bearing because everything else stubs it is rare and
  worth keeping.

- [strengths] Re-verified every load-bearing factual claim against the vendored source
  independently of round 1, and all of them hold: exactly 15 `nvim_create_user_command`
  calls matching t-3's list; `return false, "Already running"` verbatim (init.lua:479);
  `M.lock_dir = get_lock_dir()` at module load (lockfile.lua:20) and the
  `<lock_dir>/<port>.lock` path shape; `auto_start = true` / `track_selection = true` /
  `terminal.provider = "auto"` as vendored defaults, so all three of t-2's forcings are
  real changes; `M.start(false)` before `M._create_commands()` before the
  `ClaudeCodeShutdown` augroup, all three inside `setup()` — which is what makes t-3's
  shim scope correct; `_clear_autocommands` clearing `"ClaudeCodeSelection"` by literal
  name (selection.lua:151); `get_status()`'s `{running, port, client_count, clients}`;
  the `CLAUDE_CODE_SSE_PORT` / `ENABLE_IDE_INTEGRATION` / `FORCE_CODE_TERMINAL` keys and
  the `no_proxy`/`NO_PROXY` loopback merge (terminal.lua:364-387); the seven required
  custom-provider methods and the fact that a table provider passes vendored validation
  and reaches `get_provider()`, so t-9's capture table is viable; `state.handlers` holding
  `"tools/call"` and `"tools/list"`; no re-entrancy guard on vendored `setup()`, which
  motivates t-6's double-setup item. `ClaudeCodeMCPDiff` is created lazily on first diff
  (diff.lua:35-37), not during setup, so t-3's list of untouched augroups is complete for
  the shim's scope even though it omits that name.

## Round-1 flags

- c-3 covered only by t-10 — RESOLVED: c-3 added to t-2 and t-5, t-10 reframed as the
  tripwire with the fix location named; the arming mechanism it introduced is FLAG 3 above.
- Pre-flight guard vs. start-opens-terminal — RESOLVED: `ensure_server()`/`start()` split,
  asserted in t-5, t-6 and t-9.
- c-4 conflation never exercised — RESOLVED: t-5's `clients = {}` / `client_count = 1`
  assertion, plus snapshot computing `connected` itself rather than delegating.
- vendor_smoke.lua silently dropped — PARTIAL: an item now asserts it stays in the
  discovered set, but that contradicts the `*_check.lua` glob and suffix assertions beside
  it (FLAG 1).
- t-1 misdescribes the busted glob / `find` precedence — RESOLVED: restated as the naming
  convention with "there is no tests/nvim exclusion" spelled out, and the parenthesised
  `-o` fix pinned with the regressing expression quoted.
- t-12 bundles c-6 and c-7 — RESOLVED: split into t-12 (coexistence) and t-13 (command
  surface), correctly placed in wave 3 rather than the suggested wave 4 since t-13 needs
  only t-1 and t-6.
- t-12's unfalsifiable checkhealth clause — REGRESSED: the fixture gained
  `lua/claudecode/health.lua` and a confident rationale, but checkhealth resolves by
  directory name, so the clause still cannot fail (FLAG 4) and the real collision points
  the other way (FLAG 5).
- t-5 in wave 2 for a test-level reason — RESOLVED: t-5 is wave 1 and the
  `describe(snapshot())` cross-check moved to t-6's seventh item.
- t-7 missing a t-6 dependency — RESOLVED: t-6 added to `depends_on` with the reason stated
  in the description.

## Summary

Still no blocking issues and seven of nine round-1 flags cleanly closed, but the checkhealth
amendment is a regression built on a wrong claim about how Neovim resolves health modules,
t-1's discovery contract now contradicts itself in three places, and t-5's new selection
arming makes t-2's `track_selection` option inert while leaking autocmds past stop.
