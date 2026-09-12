# Plan Review — owner-driven-handover

Reviewed: 2026-09-12
Plan: 1 task across 1 wave

## BLOCKING
(none)

## FLAG
- [locked-decision coverage] The `trigger_scope` decision's whole point is distinguishing `c`/`r` from `u` — "Claiming or releasing a task (`c`/`r`) never touches role, even on a task that's already in_progress." Nothing in t-1's `test_contract` exercises `c` or `r` on an in_progress task and asserts `role.get()` is unchanged; the six listed contract items only cover `d` and `u`. Since `d`/`u` already sit in their own `elseif` arm separate from `c`/`r`, the risk is low, but the locked decision's most specific claim (the "even on a task that's already in_progress" case) ends up untested by this plan.
  Suggestion: add a test_contract item that presses `c` or `r` on an in_progress task and asserts role is untouched, or note explicitly that this is already covered by existing tests (tasks_check.lua step 5/8 don't assert role at all today).

- [description completeness] The task body says to "require(\"codriver.role\") alongside the existing task_status require," but the `u` branch also needs `ownership.owner(phase_id, task_id)`, and the only existing `ownership` require in tasks.lua lives in the separate `c`/`r` `elseif` arm (not shared scope). The description names the role require explicitly but never names the ownership require the same way — an implementer following the text literally could miss that a fresh local `require("codriver.ownership")` is needed inside the `u` branch too.
  Suggestion: name both requires explicitly in the task body (role.lua and ownership.lua), matching the pattern already used for `c`/`r`.

## NOTE
- [strength] Reusing the exact notify strings from `handover_command`/`takeback_command` ("codriver: Claude is driving" / "codriver: you're driving") rather than inventing new copy is explicitly tied back to satisfying c-5 — good traceability from spec language to implementation instruction.
- [strength] Requiring `codriver.role` directly in tasks.lua (rather than calling init.lua's `handover_command`/`takeback_command`) is the only structurally sound option: init.lua already requires `codriver.tasks`, so routing through init.lua's command functions would create a require cycle. The plan doesn't call this out explicitly, but the approach it specifies avoids the cycle and still fires `role.on_change` listeners (so the session state-file publish used for hook enforcement stays correct even when the switch originates from the float).
- [strength] The failed-write case (`task_status.set` returns `ok=false` → no role lookup/switch attempted at all) is a real edge case that's easy to miss and is both described precisely and covered by its own test_contract item.
- [strength] Placing the new key-loop tests in tests/nvim/tasks_check.lua rather than tests/codriver/tasks_spec.lua matches existing convention — tasks_spec.lua's own header comment says real-window/keypress behavior belongs in the headless nvim check, not the busted spec.

## Summary
The plan is tightly scoped, all five criteria are covered by one cohesive task with specific (non-vague) test contracts, no locked decision is contradicted, and no rule is violated — the two flags are minor gaps in test coverage and description completeness, not correctness problems.
