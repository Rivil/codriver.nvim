# Plan Review — task-status-sync

Reviewed: 2026-09-11
Plan: 2 tasks across 2 waves

## BLOCKING
(none)

## FLAG
- [feasibility/c-4] `dross task status <phase> <task> in_progress` is gated behind dross's mutation-consent check ("refusing to run: no runtime.test_command is configured" / requires `dross trust`) — verified empirically against the real `dross` 0.1.0.0 binary in a sandbox. Transitions to `pending`, `done`, and `failed` are NOT gated (they succeed immediately with no trust configured); only the transition *to* `in_progress` is. This is exactly the transition the locked `u` key (revert-to-in_progress, c-4) uses. On any machine/repo where `dross trust` hasn't been run — plausible for a fresh checkout, since the trust record lives in gitignored `.dross/local.toml` — pressing `u` will fail with that dross-level consent error rather than actually reverting the task. The failure *is* structurally handled (t-1/t-2's generic non-zero-exit path returns `{ok=false, message=<stderr>}` and t-2 notifies at ERROR, satisfying c-3), so nothing corrupts — but c-4's "reversible… mirroring claim/release symmetry" will routinely not work out of the box, and the plan shows no awareness of this dross-side gate. Notably, t-2's own real-dross integration test only exercises `d` (done), never `u` (in_progress) — so this gate would not even surface as a CI/test failure; it would only be discovered by a user pressing `u` for the first time.
  Suggestion: either note this as a known limitation (surfaced via the existing error-notify path, so no code change needed), or have the plan/task description call it out explicitly so it isn't mistaken for a codriver bug when someone hits it. If verification wants to exercise it, add a `dross trust`-primed real-dross case for `u` alongside the existing `d` one.

- [test-contract-specificity] t-1's description commits to a specific fallback behavior — non-zero exit returns `message` from "the command's stderr, falling back to stdout" when stderr is empty — but no test_contract line exercises the stdout-fallback branch specifically. The existing line ("a non-zero-exit-code result returns {ok=false, message=<stderr text>}") only pins the stderr-present case.
  Suggestion: add a test_contract line (or fold into the existing one) covering a non-zero exit with empty stderr and non-empty stdout, asserting `message` comes from stdout.

## NOTE
- [check-8/strengths] The re-render-from-disk design (t-2: never mutate a local status field; on both ok=true and ok=false, `render()` is re-run fresh) makes c-3 hold structurally rather than by convention — a failed write cannot leave a stale status on screen because nothing ever writes an optimistic one.
- [check-8/strengths] Test contracts are unusually specific for both tasks — exact argv shape, exact `{ok, message}` shapes for success/non-zero-exit/spawn-failure, and the ERROR-level notify contract — which is exactly what closed the prior review's blocking gap (spawn-failure raise) and made it independently verifiable here rather than taken on faith.
- [check-8/strengths] t-1's `dross task status <phase-id> <task-id> <status>` argv matches the real installed `dross` CLI's `task status` subcommand signature exactly (verified against `dross task status --help` and a live sandbox run) — no drift between the plan's assumed CLI shape and the actual tool.
- [check-1/coverage] All four criteria (c-1..c-4) are covered: c-1/c-3 by t-1+t-2, c-2 by t-2, c-4 by t-2. No gaps.
- [check-2/locked-decisions] No conflicts found against `write_mechanism`, `trigger_surface`, `status_range`, or `ownership_on_done` — t-2's test_contract explicitly asserts ownership is untouched by d/u, and no standalone command is introduced.
- [prior-review-fix] The amendment closes the previously found BLOCKING gap: `set()` now pcall-wraps the `vim.system(...)` call itself (not just `:wait()`), and this is directly asserted by a dedicated test_contract line in t-1 plus a key-loop non-crash line in t-2. Confirmed against Neovim's `vim.system` semantics (spawn failure raises synchronously from the `vim.system()` call before a handle exists to `:wait()` on) — the fix targets the right call site.

## Summary
No blocking issues; the plan is sound and the previously-found pcall gap is genuinely closed, but the `u`/revert path (c-4) will hit dross's own `runtime.test_command`-trust gate on any untrusted repo and the plan doesn't acknowledge or test that case.
