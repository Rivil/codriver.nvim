# Plan Review — phase-binding-follow-up

Reviewed: 2026-09-11
Plan: 4 tasks across 2 waves

## BLOCKING
(none)

Both prior BLOCKING/FLAG items are verified fixed:
- The `pruning_trigger` conflict is resolved: t-1's `claim()`/`release()` accept an optional `tasks` list and prune stale phase entries before writing (matches the locked decision's wording almost verbatim). t-3 now explicitly "pass[es] the current phase's task list through to ownership.claim/release for pruning" for `:CodriverClaim`, and t-4 now explicitly calls `ownership.claim(phase_id, task_id, tasks)` / `ownership.release(phase_id, task_id, tasks)` from the float "so stale entries prune on every float-driven write too, same as :CodriverClaim". Both production call sites thread the list through.
- The header-format FLAG is resolved: t-2's contract pins the exact string `"yours: <human-count>  claude: <claude-count>"`.
- The header-in-real-buffer FLAG is resolved, and placed correctly: the new test_contract line ("the header line appears as the first line of the real buffer opened by open()/_show()") sits on t-4, which owns `tests/nvim/tasks_check.lua` — not on t-2, which only owns the busted spec (`tests/codriver/tasks_spec.lua`) and has no access to a real buffer. Correct task assignment.

## FLAG
- [test-contract-specificity] t-4 relies on cursor position mapping to a task id ("`c`/`r` ... the task under the cursor") but no task or test_contract pins down the mechanism: whether `render()`'s return gains a raw tasks/ids field for `open()` to index against, or whether `open()` performs its own independent `dross.read()` call alongside `render()`. t-4's description phrase "already available from render()'s underlying dross.read() result" is ambiguous between those two shapes, and t-2 (which touches `render()` last before t-4) only documents adding a `header` field, not a tasks/ids field. The externally observable behavior is tested, so this isn't blocking, but the shape is left underspecified for the implementer.
  Suggestion: either have t-2 (or t-4) explicitly state whether `CodriverTasksRender` gains a `tasks`/ids field, or state that `open()` calls `dross.read()` directly for the id list independent of `render()`.

- [test-contract-specificity] t-2's header contract has no freshness assertion analogous to the existing `tasks_spec.lua` test "re-reads dross.read() on every call" for `lines`. Nothing pins that `header`'s human/claude counts update across two successive `render()` calls when ownership changes in between — only that the count is correct for a single snapshot ("for the phase's current tasks").
  Suggestion: add a test_contract line (or rely on the existing re-read test being extended) asserting the header changes across two `render()` calls straddling an ownership change, mirroring the existing `lines` re-read coverage.

- [coverage-consistency] t-4's test_contract asserts stale-entry pruning through the float's `c`/`r` path (directly relevant to c-4), but t-4's `covers` field lists only `["c-2"]`. c-4 is already covered by t-1 and t-3, so this isn't a BLOCKING coverage gap — but the `covers` field undersells what t-4 actually verifies for that criterion.
  Suggestion: add `"c-4"` to t-4's `covers`, or leave as-is if the convention is "covers" means "primary owner of," not "touches."

## NOTE
- [pruning-interaction] Pruning and the existing `is_known`/WARN path are orthogonal but interact: claiming/releasing a task id absent from the current tasks list still WARNs and records the entry (unchanged behavior). That entry will itself be pruned as "stale" on the *next* claim/release write for the same phase, since it remains absent from the list. This is consistent with the locked `pruning_trigger` decision (self-healing, no standalone prune command) but isn't called out anywhere in t-1's test_contract. Worth the author's awareness; no action required.
- [global-rules] `/Users/rivil/.claude/dross/rules.toml` does not exist — no global rules to cross-check against this plan.

## Strengths
- [wave-order] Wave dependencies are precisely scoped rather than conservatively over-declared: t-3 depends only on t-1 (needs `release()`), correctly omitting t-2 since `:CodriverClaim` never touches the header/float.
- [locked-decision-fidelity] Task descriptions quote the locked decisions almost verbatim (`pruning_trigger`, `release_command`, `float_interaction`), minimizing interpretation drift between spec and implementer.
- [fix-placement] Both amendments from the prior review pass were not just made but placed on the correct task: the real-buffer header assertion landed on t-4 (which owns the nvim headless check file), not t-2 (which only owns the busted unit spec and has no real `vim.api` window to assert against).

## Summary
No blocking issues; the plan correctly threads ownership pruning through both real call sites and places its test assertions on the tasks that actually own the relevant files, leaving only minor specification gaps (cursor-to-task-id mechanism, header freshness testing, one covers-field omission) for the author to consider.
