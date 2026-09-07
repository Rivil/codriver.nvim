# Plan Review — handover

Reviewed: 2026-09-07
Plan: 5 tasks across 2 waves

## BLOCKING
(none)

## FLAG
- [wave order] t-1 and t-3 (both wave 1, no `depends_on`) both edit `tests/codriver/init_spec.lua`, not just `lua/codriver/init.lua`. The prior review's fix note only carves disjoint regions of `M.setup()` in the production file ("t-3 = top, before publish_role; t-1 = further down, near command wiring") — neither task description says where in the spec file its new test cases land. Test-file edits (new `describe`/`it` blocks, both plausibly touching the same `setup()` `describe` block and reusing the same fake-vendor/state fixtures already in that file) are more collision-prone than the production-code split, since two independently-authored insertions into the same region of a spec file are harder to auto-merge cleanly than two disjoint hunks in a well-commented function.
  Suggestion: name the target `describe` block for each task's new tests (e.g. "t-3's tests go in a new `describe('reload')` block; t-1's in a new `describe('handover commands')` block, both appended after the existing top-level `describe('setup', ...)`"), or add `depends_on = ["t-3"]` (or vice versa) to serialize the two edits since neither functionally depends on the other's output but both land in the same file.

## NOTE
- [locked-decision consistency] Re-verified against source: `multi_instance_tiebreak`'s reworded text ("state file scoped per-instance, keyed by that instance's pid... never written to a shared file") matches `lua/codriver/hook/state.lua:4-6` (`M.path()` uses `vim.uv.os_getpid()`) and `lua/codriver/config.lua:174-185` (per-setup-call `channel.state_file` injected into that instance's own vendored env). t-4's description and test_contract are internally consistent with this — no conflict found. The prior BLOCKING finding is resolved.
- [test contract grounding] t-2's description claims `hook_decision_spec.lua`'s test at "line ~101" is titled "...and never names a handover command" and needs both title and body updated. Independently confirmed: line 101 reads exactly `it("names the navigator role, is harness-level and not retryable, and never names a handover command", function()`, and `tests/nvim/enforcement_write_check.lua:93-100` has the matching runtime assertion (`not ...:find(":Codriver", ...)`) t-2 says to flip. Both citations are accurate.
- [coverage correction verified] t-2's `covers = []` (down from the prior review's flagged `["c-1"]`) is correct: c-1 ("a user command hands the keyboard... callable at any point") is fully satisfied by t-1 alone, which registers both commands and wires them to `role.set()`. t-2 only changes a refusal string and two test assertions, unrelated to c-1's own satisfaction.
- [runner wiring] New files `tests/nvim/multi_instance_check.lua` (t-4) and `tests/nvim/handover_write_check.lua` (t-5) need no separate registration task — `mise.toml`'s `test-nvim` task globs `tests/nvim/*_check.lua` and runs each in its own headless Neovim, confirmed in `mise.toml:135-180`.

## Summary
The BLOCKING locked-decision conflict from the prior review is genuinely fixed and internally consistent with the real per-pid state architecture; the plan is close to ship-ready, with one real (if narrower-than-before) same-wave file-collision risk remaining between t-1 and t-3 on `tests/codriver/init_spec.lua`.
