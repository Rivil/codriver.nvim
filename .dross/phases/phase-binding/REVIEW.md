# Plan Review — phase-binding

Reviewed: 2026-09-09
Plan: 4 tasks across 3 waves

## BLOCKING
(none)

## FLAG
- [wave-order] t-2 and t-3 are both in wave 2, both depend only on t-1, and both list `lua/codriver/init.lua` in their `files`. t-2 wires `:CodriverClaim` into init.lua; t-3 wires the untracked-session `vim.notify` into `start_command` in the same file. Neither task's description or test_contract references the other, so there's no ordering dependency between them — but if wave 2 is executed as a parallel batch (rather than serialized by the pair-mode human), two tasks editing the same file concurrently risks a conflicting diff/merge, or one task's edit silently clobbering the other's insertion point in init.lua.
  Suggestion: either serialize t-2 and t-3 (one depends_on the other) or note in the plan that same-wave tasks touching a shared file are expected to run sequentially, not concurrently.

- [antipattern] t-4's test_contract line "with no active phase or a corrupt plan.toml, :CodriverTasks notifies instead of opening a buffer or erroring" duplicates part of t-1's and t-3's coverage of c-5 (degrade gracefully). Not wrong — c-5 legitimately needs a check at t-4's own call site — but worth noting the phase has three separate "does not crash on missing/corrupt dross files" tests (t-1, t-3, t-4) with no shared fixture referenced across them, which is a minor duplication-of-effort risk if the fixture format ever changes.
  Suggestion: confirm t-1, t-3, t-4's malformed-plan.toml fixtures are the same fixture (or generated the same way) so a schema drift doesn't require fixing three fixtures independently.

## NOTE
- [rules] `/Users/rivil/.claude/dross/rules.toml` (global rules) does not exist on this machine — no global rules were available to cross-reference. Only project-level rules.toml (r-01: never run `dross project set`; r-02: never hand-edit vendor/) applied, and no task violates either.
- [granularity] All four tasks stay in the 2-4 file range with no task spanning more than two logical layers (core module + command wiring, or module + test). No split or merge candidates.
- [locked-decisions] All four `locked = true` decisions in spec.toml map cleanly onto exactly one task each with no drift: ownership_source → t-2's local `.dross/.codriver-ownership.json` keyed by (phase_id, task_id); dross_dependency → t-1 reading state.json/plan.toml directly with no CLI shell-out; untracked_indication → t-3's single WARN vim.notify; task_list_surface → t-4's scratch buffer closing on any key.
- [strength] t-1 deliberately scopes plan.toml parsing to a narrow field-extractor (id/title/status only) rather than reaching for a full TOML library that doesn't exist in the repo — avoids scope creep into writing/maintaining a general parser.
- [strength] Every test_contract across all four tasks names a concrete behavior or return shape (e.g. `{available=false, reason="corrupt"}`, `M.claim`/`M.owner` semantics, "fires exactly one WARN-level vim.notify") — no vague "tests pass" contracts anywhere in the plan.
- [strength] t-2's ownership store is keyed by `(phase_id, task_id)` rather than just `task_id` — proactively guards against task-id collisions across phases that reuse ids like "t-1", which the spec doesn't explicitly demand but strengthens correctness.

## Summary
Coverage, locked decisions, and test-contract specificity are all clean; the only real risk is two same-wave tasks (t-2, t-3) editing `lua/codriver/init.lua` with no explicit ordering between them.
