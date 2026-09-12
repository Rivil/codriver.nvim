# Plan Review — write-allowlist

Reviewed: 2026-09-12
Plan: 3 tasks across 1 wave

## Prior review verification

- match_semantics BLOCKING: RESOLVED. spec.toml's decision now reads "equals a configured prefix
  string exactly, or starts with the prefix followed by a path separator," and t-2's description and
  test_contract ("notes" vs "notes-leak/secret.md") match it exactly. No remaining gap.
- health.lua parity FLAG: RESOLVED. t-1 now includes lua/codriver/health.lua and a
  check_write_allowlist test_contract line.
- hook_state_check.lua / hook_publish_check.lua FLAG: RESOLVED. t-3 now includes both files, and the
  new test_contract lines are plausible against the real files — hook_state_check.lua already has a
  "7b." bash_allow round-trip section (lines 221-233) and hook_publish_check.lua already asserts
  bash_allow on initial publish (lines 79-83) and on role-flip republish (lines 137-141); write_allow
  assertions mirroring those are a straightforward, well-specified addition.
- c-1/t-1 coverage FLAG: RESOLVED. t-1's covers now includes c-1 alongside c-5.

## BLOCKING
(none)

## FLAG

- [granularity] t-1 bundles three concerns — config validation (config.lua), user docs (README.md),
  and a checkhealth surface (health.lua) — into one task, 5 files. This is not actually "mirroring an
  existing pattern": the direct precedent for this exact feature shape is bash_allow's own
  introduction (commit f5dfef6, phase public-config-surface), which split these into three separate
  tasks — t-1 (config.lua only), t-5 (README.md only), and t-4 (health.lua only, with its own
  depends_on). The current t-1 collapses exactly the three concerns that phase kept apart. Each piece
  is individually small, but they land as one commit reviewable only as a whole, and a config-only
  regression (e.g. a validate_string_list mistake) can't be isolated from a docs wording change in
  the diff.
  Suggestion: split t-1 into a config task (config.lua + config_spec.lua) and either one combined
  docs/health task or two further splits, matching the established precedent — or explicitly note in
  the plan why this phase's smaller surface area justifies departing from it.

- [test contract specificity] t-2's test_contract only exercises Write and Edit, plus Bash as a
  negative control. c-1 and t-2's own description name all four tools — Edit/Write/MultiEdit/
  NotebookEdit — and the description explicitly calls out that the target path is extracted from
  either `file_path` or `notebook_path` depending on tool. NotebookEdit's field name differs from the
  other three, which is exactly the kind of branch a test contract should pin down, and it currently
  isn't tested at all; MultiEdit is untested too (existing hook_decision_spec.lua already has a
  precedent loop over all four tools for the deny case, so the same shape was available here).
  Suggestion: add at least one test_contract line asserting a NotebookEdit call is matched via
  `notebook_path`, and one confirming MultiEdit is covered by the same prefix check as Write/Edit.

- [test contract specificity] t-1's checkhealth test_contract line ("reports the effective
  write_allow prefixes, mirroring check_bash_allowlist's output") borrows the word "effective" from
  bash.lua's `effective_allowlist()`, which merges hardcoded defaults with bash_allow additions.
  write_allow has no hardcoded defaults per the overbroad_entries decision (an empty/omitted
  write_allow means nothing is writable, c-4) — there is nothing to merge, only the raw configured
  list to print. As worded, an implementer could read this as "build a write_allow analog of
  effective_allowlist," which is unnecessary surface area.
  Suggestion: reword to something like "reports the configured write_allow prefixes verbatim" to
  avoid implying a merge step that shouldn't exist.

## NOTE

- [strengths] The match_semantics fix is carried through consistently end to end: the locked decision,
  t-2's description, and t-2's test_contract all use the same segment-boundary language and the same
  "notes" / "notes-leak" example, rather than three independently-worded restatements that could drift.
- [strengths] t-3's extension of hook_state_check.lua and hook_publish_check.lua asks for real
  filesystem/pid-backed assertions rather than settling for busted-level fakes, matching this
  repo's own stated rationale for keeping that lane ("every claim it makes is about the real world" —
  hook_state_check.lua's file header) rather than treating it as boilerplate to copy.
- [strengths] bash_scope is respected precisely: t-2 explicitly declines to extend write_allow to
  Bash and adds a test proving a Bash call targeting an allowed path is still governed solely by
  bash.allows — closing off the exact escape the locked decision's rationale warns about.

## Summary
No blocking issues; the previously-blocking match_semantics wording and all three flags are
genuinely fixed, but t-1's three-concern bundling departs from this repo's own precedent for the
same feature shape and t-2's test contract has a real coverage gap on MultiEdit/NotebookEdit that
should be closed before execution.
