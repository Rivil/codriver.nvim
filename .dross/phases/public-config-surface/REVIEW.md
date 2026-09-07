# Plan Review — public-config-surface

Reviewed: 2026-09-07
Plan: 5 tasks across 3 waves

## BLOCKING
(none)

## FLAG
- [test_contract-coverage] t-3's third test_contract bullet — "a role-change republish does not drop a previously-resolved bash_allow, mirroring existing test_command preservation" — names an integration behaviour that currently has exactly one home: `tests/nvim/hook_publish_check.lua` lines 110-120, which drives `require("codriver").setup(...)` then `role.set("driver")` and asserts `state.read(state.path()).test_command` survives the republish. t-3's files list is `lua/codriver/init.lua`, `lua/codriver/hook/state.lua`, `lua/codriver/hook/decision.lua`, `tests/codriver/hook_decision_spec.lua`, `tests/nvim/hook_state_check.lua`. `hook_decision_spec.lua` is a pure busted spec for `decision.decide` and never calls `setup()`/`role.set()`; `hook_state_check.lua` calls `state.publish`/`state.read` directly but never goes through `init.lua`'s `publish_role` closure or a live role flip. Neither listed file can exercise the actual setup()→role.set()→republish path the bullet describes.
  Suggestion: add `tests/nvim/hook_publish_check.lua` to t-3's files list, or narrow the third bullet to what `hook_state_check.lua` can actually prove (direct `state.publish`/`state.read` round-trip, already covered by bullet two) and drop the "mirroring... republish" claim.

- [granularity] t-3 touches 5 files — `lua/codriver/init.lua`, `lua/codriver/hook/state.lua`, `lua/codriver/hook/decision.lua`, `tests/codriver/hook_decision_spec.lua`, `tests/nvim/hook_state_check.lua` — crossing three distinct modules/responsibilities: setup/session wiring (init.lua), on-disk persistence (state.lua), and decision-core policy (decision.lua). This sits at the split-candidate threshold.
  Suggestion: consider splitting into "thread bash_allow through state persistence + init.lua publish/read" (init.lua, state.lua, hook_state_check.lua) and "wire session.bash_allow into decision.lua's bash.allows() call, expose resolved config for t-4" (init.lua, decision.lua, hook_decision_spec.lua).

- [test_contract-specificity] spec.toml's locked `validation_depth` decision requires every bash_allow entry to be a "non-empty string" (line 40), and t-1's own description repeats "non-empty string". None of t-1's six test_contract bullets exercise an empty-string entry (e.g. `bash_allow.heads = {""}`) — only non-string-typed entries are tested ("a non-string entry inside bash_allow.heads raises an error..."). An implementation that checks `type(entry) == "string"` without also rejecting `entry == ""` would pass every listed test while violating the locked decision.
  Suggestion: add a test_contract bullet asserting an empty-string entry inside heads/git_subcommands raises the setup()-time error.

## NOTE
- [rules] `~/.claude/dross/rules.toml` (global rules) does not exist on this machine — nothing to cross-check there; project rules.toml (r-01 never run `dross project set`, r-02 never hand-edit `lua/codriver/vendor/`) were checked and no task touches project.toml or anything under `vendor/`.
- [strength] All 5 spec criteria (c-1..c-5) are mapped to at least one task's `covers`, and every file the plan references — `lua/codriver/config.lua`, `lua/codriver/hook/bash.lua`, `lua/codriver/init.lua`, `lua/codriver/hook/state.lua`, `lua/codriver/hook/decision.lua`, `lua/codriver/health.lua`, `README.md`, and all five listed test files — was verified to exist in the repo.
- [strength] All four locked decisions in spec.toml (allowlist_shape, allowlist_key, validation_depth, unsafe_additions) are faithfully reflected in task descriptions and test contracts; no contradictions found.
- [strength] The wave/dependency graph is minimal and each cross-wave dependency is real: t-3 (wave 2) needs t-1's `resolved.codriver.bash_allow` and t-2's extended `bash.allows()` signature; t-4 (wave 3) needs t-3's module-exposed config and t-2's `effective_allowlist()`. Wave-1 tasks (t-1, t-2, t-5) are correctly independent of one another — t-5 can be written from the spec's locked shape without waiting on implementation.

## Summary
No blocking issues; the plan is sound on coverage, locked-decision fidelity, and wave ordering, but t-3's test contract references an integration test that its own file list cannot produce and is a genuine split candidate, and t-1's test contract under-tests the "non-empty string" half of its own validation requirement.
