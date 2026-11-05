# Plan Review — ambient-review-on-save

Reviewed: 2026-09-12
Plan: 11 tasks across 3 waves

## BLOCKING
(none)

## FLAG
- [granularity] t-11 ("Register Stop hook, verify end-to-end RPC render") touches 5 files
  (scripts/codriver-review-hook.lua, lua/codriver/session.lua, lua/codriver/init.lua,
  tests/nvim/review_hook_check.lua, tests/nvim/hook_settings_check.lua) and spans three
  concerns: writing the new hook script, wiring its registration into session.lua, and
  updating/extending two separate test files. It also crams "register" and "verify
  end-to-end" into one title, which is the "one task that should be two" antipattern.
  Suggestion: split into (a) write scripts/codriver-review-hook.lua + wire
  session.lua's hooks.Stop registration, and (b) the end-to-end RPC-render
  verification pass. If the split feels artificial given how tightly the wiring and
  its test are coupled, at minimum drop the unexplained lua/codriver/init.lua edit
  (see next finding) to get back under the file-count threshold.

- [antipattern: unclear file] t-11 lists `lua/codriver/init.lua` as a file it touches,
  but nothing in its description or test_contract names what changes there. t-10
  already wires the BufWritePost/autosave path into init.lua; the only plausible
  reason for t-11 to touch it again is updating the docstring's "not implemented yet"
  list (init.lua currently says "ambient review on save... [is] not implemented yet").
  That's a legitimate cleanup but is undocumented in the task, so a reader (or the
  executing agent) can't tell what's actually supposed to change there.
  Suggestion: either name the init.lua change explicitly in the description, or drop
  it from `files` if it turns out t-10's wiring is already sufficient.

- [antipattern: naming collision] t-9 creates `lua/codriver/review/notify.lua`, and
  the repo already has `lua/codriver/hook/notify.lua` (existing RPC receiver for
  refused-write announcements, same shape: called over RPC by a hook script). Two
  modules named `notify` doing structurally the same job (RPC receiver -> render/
  announce) in sibling directories is easy to mis-`require` under time pressure.
  Suggestion: no functional problem, but consider a more specific name
  (e.g. `review/receiver.lua`) or explicitly note the parallel to hook/notify.lua in
  the task description so it reads as a deliberate mirror, not an accidental
  duplicate.

## NOTE
- [coverage] All six criteria (c-1..c-6) trace to at least one task's `covers` field,
  and the mapping is accurate on inspection (e.g. t-10's covers list — c-1,c-2,c-3,
  c-5,c-6 — matches what its test_contract actually exercises).
- [locked decisions] No conflicts found. Verified against the real code: `diff_basis`
  matches t-2/t-3's snapshot-advances-after-review design and t-10's "failed send
  does not advance the snapshot" rule; `delivery_mechanism` matches the real
  `terminal.send_to_terminal(text, opts)` signature and boolean return in
  lua/codriver/vendor/claudecode/terminal.lua:671 exactly (t-10's contract for the
  false-return path is not speculative — it names the real return type); `rendering_
  surface` is virtual-text-only with no quickfix anywhere in the plan;
  `save_cadence` debounce + async dispatch (t-4, t-10) matches with no polling/
  blocking loop introduced.
- [forbidden actions] No task touches lua/codriver/vendor/ (r-02) or
  .dross/project.toml (r-01). No violations against project or global rules.
- [wave parallelism] Wave 1's 8 tasks touch entirely disjoint file sets — genuine
  parallelism, not just declared-parallel-but-actually-serial.
- [wave ordering] t-9 (wave 2) and t-10 (wave 2) each correctly need outputs from
  multiple wave-1 tasks; t-11 (wave 3) correctly needs t-9's wave-2 output. No task
  is over-staged into a later wave than its dependencies require.
- [test contract specificity] Contracts consistently name the exact function,
  input, and observable output (e.g. t-9: "a comment for a file with no matching
  loaded buffer (bufnr == -1) raises nothing and adds no extmark"). No vague
  "tests pass"-style contracts found.
- [strength] Test contracts were checked against real signatures, not invented ones:
  t-10's send_to_terminal contract matches the vendored function's actual signature
  and return semantics; t-7's "3rd arg omitted defaults to PreToolUse" matches the
  real 2-arg call site at session.lua:88 that must keep working.
- [strength] File-naming conventions match the existing split between
  tests/codriver/*_spec.lua (pure busted specs) and tests/nvim/*_check.lua (headless
  Neovim integration checks) throughout — e.g. t-1's config test lands in
  tests/codriver/, t-8's extmark renderer test correctly lands in tests/nvim/ since
  it needs a real buffer/namespace.
- [strength] Failure paths are built into contracts rather than assumed away: t-10's
  snapshot-not-advanced-on-failed-send, and t-9's cleared-pending-marker guard
  against a duplicate Stop event double-rendering.

## Summary
No blocking issues; the plan's coverage, locked-decision fidelity, and test-contract
specificity all hold up against the real code, with t-11 the one task worth trimming
or splitting before execution.
