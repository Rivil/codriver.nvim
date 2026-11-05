# Plan Review — shorten-send-commands

Reviewed: 2026-09-12
Plan: 2 tasks across 2 waves

## BLOCKING
(none)

## FLAG
- [technical-verification] t-2's description justifies mapping visual mode to the plain `:CodriverSend<CR>` form over `<Cmd>CodriverSend<CR>` with: "the plain `:` form is required in visual mode... `<Cmd>` would bypass that and send the whole buffer instead." This is not supported by the vendored code. Empirically confirmed under headless nvim (0.12.4): a `<Cmd>Foo<CR>` visual-mode mapping keeps `vim.fn.mode()` reporting `V`/`v` when the command handler runs (does not exit Visual mode the way `:` does). `visual_commands.create_visual_command_wrapper` (lua/codriver/vendor/claudecode/visual_commands.lua:215-226) branches purely on `vim.fn.mode()`, not on whether the invocation carried a `'<,'>` prefix — so a `<Cmd>`-triggered call in visual mode would still take the `exit_visual_and_schedule` branch, feed `<Esc>` itself, and read `'<`/`'>` off the freshly-set marks (lines 856-868 of vendor/claudecode/init.lua), landing on the same correct range as the `:` form. Neither form would "send the whole buffer." The chosen technique (`:`) is still correct and will satisfy t-2's own test_contract line about the visual range, but the stated rationale for rejecting `<Cmd>` is wrong and shouldn't be carried into code comments/README prose as written.
  Suggestion: Either verify this claim before implementing and correct the description's reasoning (e.g., "`:` is the more conventional/simpler idiom for a ranged command" is defensible; "`<Cmd>` sends the whole buffer" is not), or drop the specific technical justification if it can't be re-verified.

- [criteria-fidelity] t-1's description narrows spec.toml's c-5 ("Setting a keymap to false/nil disables it") to only `false` disabling, explicitly excluding `nil`/omission as a distinct case, citing "the confirmed reading of c-5." This reading is technically necessary — Lua cannot distinguish `opts.keys.send = nil` from omitting the key entirely, so c-5's literal text is partly unimplementable as written — but spec.toml itself was never updated to reflect the narrowed reading. A future reader of spec.toml alone (without plan.toml's aside) would reasonably expect `nil` to behave as a distinct disable trigger, which it doesn't and can't.
  Suggestion: Since this is a criteria-text/plan mismatch rather than a locked-decision conflict, it's not blocking, but spec.toml's c-5 wording is now stale relative to what's actually being built and should be corrected for anyone reading the spec in isolation.

- [implementation-gap] t-1's description details the validation and merge rules for `opts.keys` but never explicitly states that the resolved keys table must be exposed on `M.resolve`'s return value (currently `{ codriver = { auto_start, test_command, bash_allow }, claudecode }` at lua/codriver/config.lua:242-245). t-2 consumes `resolved.codriver.keys` directly, so t-1 implicitly must add a `keys` field there — but nothing in t-1's description or test_contract asserts on `resolved.codriver.keys` by that exact path (contracts describe "the resolved table" generically). It's inferable from context, but it's the one piece of wiring between the two tasks' contracts that isn't spelled out anywhere.
  Suggestion: worth a one-line addition to t-1's description or test_contract naming `resolved.codriver.keys` explicitly, since it's the literal handoff point t-2 depends on.

## NOTE
- [check-4/granularity] t-2 touches 4 files (lua/codriver/keymaps.lua, lua/codriver/init.lua, README.md, tests/nvim/keymaps_check.lua) across implementation + wiring + docs + tests. Under the 5-file threshold and the work is cohesive (one feature, one wave), so not flagged as a split candidate — but it's the fuller of the two tasks and the closest to that line.
- [check-6/antipatterns] No "set up X" filler tasks, no artificial splits, no files referenced that don't already exist or aren't created within the same task. keymaps.lua and tests/nvim/keymaps_check.lua are new files created by t-2 itself, correctly following the existing `*_check.lua` / harness.lua convention already present in tests/nvim/.
- [strength] Test contracts throughout are concrete and behavior-specific ("absent from the resolved keys table," "scoped to exactly the visually-selected line range, not the whole buffer," "leaves `<leader>cs` itself unmapped") rather than "tests pass" — no FLAG needed for check 3.
- [strength] The wave split mirrors the repo's own test-tier convention (tests/codriver/ pure-Lua unit tests for t-1's config-resolution logic vs. tests/nvim/ headless-Neovim integration tests for t-2's actual keymap wiring), and the wave-2 dependency on wave-1 is a genuine data dependency (t-2 needs t-1's resolved-keys shape), not padding for parallelism optics.
- [strength] Both tasks stay entirely within wrapper-module territory (config.lua, keymaps.lua, init.lua) — nothing touches lua/codriver/vendor/, correctly honoring project rule r-02.

## Summary
No blocking issues; the plan has full criteria coverage and clean wave/dependency structure, but one task description carries an incorrect technical justification (the `<Cmd>` vs `:` claim) and one criterion's text is stale relative to the narrowed interpretation the plan is actually building against.
