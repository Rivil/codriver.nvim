# Plan Review — handover

Reviewed: 2026-09-07
Plan: 5 tasks across 2 waves

## BLOCKING

- [locked-decision-conflict] Task t-4 contradicts the `multi_instance_tiebreak` locked decision's stated mechanism and explicit rejection.
  The decision's `choice` is "Last-writer-wins: whichever Neovim instance most recently published a role change to the shared state file is authoritative for the hook's decision," and its `why` explicitly rejects the alternative: "A stricter per-instance scheme would be a bigger change to a decision role-enforcement already locked." t-4's description instead argues no such shared file or race exists at all — "per-pid state files plus per-instance env injection already give a well-defined tie-break with no shared mutable resource to race" — and its test contract requires the *opposite* of last-writer-wins: instance A's hook decision must never be swayed by instance B's more-recently-published role, even when B is the "last writer" globally. Verified against `lua/codriver/hook/state.lua`: `M.path()` is keyed by `vim.uv.os_getpid()` (line 5), and `lua/codriver/config.lua` (lines 174-185) injects that per-instance path into `CODRIVER_STATE_FILE` for that instance's own Claude terminal only — there is genuinely no shared file two instances write to, confirming t-4's technical claim over the decision's premise. The locked decision was apparently written assuming a shared/racy resource that doesn't exist in the actual (pre-existing, from role-enforcement) architecture, and t-4 silently overrides that premise rather than resolving the conflict.
  Suggestion: Reconcile before proceeding — either amend the locked decision's text (it appears to predate or ignore the per-pid file architecture) or change t-4 to actually implement and test last-writer-wins semantics against a genuinely shared resource, matching the decision as written. Don't let t-4 quietly redefine what the locked decision says.

## FLAG

- [wave-order / file-overlap] t-1 and t-3 are both wave 1 (no `depends_on` between them) and both modify the exact same two files: `lua/codriver/init.lua` and `tests/codriver/init_spec.lua`. t-1 adds two `vim.api.nvim_create_user_command` registrations inside `M.setup()`; t-3 adds role-restoration logic that must run "before `publish_role(M.role.get())` runs in `setup()`" — also inside `M.setup()`. Same-wave tasks touching the same function in the same file risk stale diffs or merge conflicts depending on execution order, since neither depends on the other's output but both are editing overlapping code.
  Suggestion: Either sequence them with a `depends_on` edge, or note explicitly that they touch disjoint regions of `setup()` and coordinate insertion order so whichever lands second doesn't have to rebase around the first's edit.

- [coverage-precision] t-2 lists `c-1` in `covers`, but its actual content (naming `:CodriverHandover` in the navigator refusal reason) doesn't make the command "callable" — that's entirely t-1's doing. c-1 already has real coverage from t-1, so this isn't a gap, but t-2's `covers` entry for c-1 is an overclaim that muddies which task actually satisfies which criterion.
  Suggestion: Consider whether t-2 covering c-1 is intentional (e.g. "discoverability" reading of c-1) or should be dropped, since t-1 alone already satisfies it.

## NOTE

- [test-contract-completeness] `tests/codriver/hook_decision_spec.lua`'s test at line 101 is itself titled `"names the navigator role, is harness-level and not retryable, and never names a handover command"`. t-2's contract only requires flipping the assertion body (`assert.is_nil` → presence check); the test's own title still says "never names a handover command" and would read self-contradictory if left as-is. Not blocking — just something the implementer should catch since the plan doesn't call it out.

- [grounding] t-1's description says command registration "must survive a second `setup()` call the same way the existing role listener does." The two mechanisms actually differ: the role listener is guarded by `enforcement_hooked`/`first_setup` to avoid stacking duplicate listeners, while `nvim_create_user_command` is naturally idempotent on re-registration and needs no such guard. The outcome (`survives being set up twice`) is the same; the mechanism described is not. Low risk of misleading the implementer, but worth a precise read.

- [strength] Test contracts throughout are unusually concrete and independently verified against the real codebase — e.g. t-1's "existing 'survives being set up twice' test pattern" (verified at `tests/codriver/init_spec.lua:378`) and t-2's "names no handover command that does not exist yet" assertion (verified verbatim at `tests/nvim/enforcement_write_check.lua:96-100` and `tests/codriver/hook_decision_spec.lua:112`) are both real, existing assertions being flipped, not invented ones.

- [strength] t-5 deliberately keeps c-2 and c-3 (unblock, then re-block) in a single continuous headless check rather than splitting them, which is the right call given the criteria's own language ("without restarting the session," "in the same session") — splitting into two checks would risk losing the exact property being tested (session continuity across the round trip).

- [strength] t-4's "no production code change" framing is honest about the plan not manufacturing work where the architecture already provides the property — a good instinct even though (see BLOCKING above) it collides with how the locked decision is worded.

## Summary
One locked-decision conflict blocks the plan (t-4 vs. `multi_instance_tiebreak`) and needs resolution before execution; test-contract quality and grounding in the real codebase are otherwise strong.
