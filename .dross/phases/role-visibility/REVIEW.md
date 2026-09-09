# Plan Review — role-visibility

Reviewed: 2026-09-07
Plan: 3 tasks across 3 waves

## BLOCKING
(none)

## FLAG
- [antipattern / interface boundary] t-3's description says it "Hooks codriver.winbar's show/hide into the session lifecycle" — implying `winbar.lua` exposes public `show()`/`hide()` functions t-3 calls into. But t-2 (the task that creates `lua/codriver/winbar.lua`) never mentions a show/hide API in its description — it only describes registering highlight groups, rendering from `codriver.statusline`, and subscribing to `role.on_change`. And t-3's `files` list is `["lua/codriver/init.lua", "tests/nvim/winbar_lifecycle_check.lua"]` — it does not include `lua/codriver/winbar.lua`. So either t-2 is silently expected to build show/hide (undocumented in its description), or t-3 needs to touch `winbar.lua` to add it (undocumented in its files list). Given the codebase's established pure/impure split (status.lua pure + session.lua impure is the explicit precedent cited by t-1's own description), show/hide state belongs in `winbar.lua`, not bolted onto `init.lua` directly.
  Suggestion: either add the show/hide contract to t-2's description explicitly, or add `lua/codriver/winbar.lua` to t-3's files list — whichever task is meant to own that toggle.

## NOTE
- [locked-decision sequencing] t-2's own scope (rendering wired into `init.setup()`) would, in isolation, put a role indicator in the winbar before any session exists — which reads as contradicting the `no_session_lifecycle` locked decision. This isn't a real conflict: t-2's test_contract only asserts behaviour *after* a session starts, and t-3 (same phase, next wave) closes the gap before the phase is verified as a whole. Flagging only so it's clear this is deliberate incremental construction, not an oversight, when the plan is read task-by-task rather than as a whole.
- [check-3 / test contract specificity] Contracts throughout are unusually concrete for an LLM-authored plan — e.g. t-1's "label strings share no common stem/word" and t-2's "...with no explicit redraw command issued by the check, proving the update is pushed from role.on_change rather than lazily re-evaluated" name the exact failure mode being guarded against, not just "tests pass."
- [architecture consistency] The pure/impure split (t-1: `statusline.lua`, no `vim.*` calls / t-2: `winbar.lua`, impure wiring) explicitly mirrors the existing `status.lua`/`session.lua` split already in the codebase, and t-1's description says so. Same for the label/highlight-group approach matching `status.lua`'s WAITING/ATTACHED "share no common stem" rule.
- [wave order] All three dependency edges (t-1→t-2, t-2→t-3) are genuine build-order dependencies, not artificial serialization — t-2 needs t-1's label/highlight data to render, t-3 needs a winbar to gate. No parallelism was left on the table.

## Summary
No blocking issues and no missing coverage or locked-decision violations; the one real gap is an underspecified interface boundary between t-2 and t-3 over which module owns show/hide, worth resolving before or during t-3's execution.
