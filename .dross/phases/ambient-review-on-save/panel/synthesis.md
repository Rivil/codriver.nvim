# Synthesis — ambient-review-on-save

Grounded against the live tree before scoring: `lua/codriver/config.lua`
(`M.resolve(opts, channel)` returns `{codriver = {...}, claudecode = {...}}`,
`auto_start`'s boolean-or-error pattern), `lua/codriver/hook/claude_settings.lua`
(`M.merge(existing, command)` is 2-arg today, hardcoded to `PreToolUse`),
`lua/codriver/hook/state.lua` (`publish()` hardcodes its field list —
`role`/`test_command`/`bash_allow`/`write_allow` — new fields need an explicit
add), `lua/codriver/session.lua:88` (`claude_settings().install(path,
hook_command())`, the one call site any signature change must not break), and
`lua/codriver/hook/decision.lua` (the PreToolUse gate that already refuses
Edit/Write/Bash-write at the harness level when navigator).

## Scores

| Draft | Criteria coverage | Test-contract specificity | Granularity | Wave correctness |
|---|---|---|---|---|
| risk (9t/3w) | Full, well distributed across 9 tasks | Concrete Lua examples; catches the send-failure edge case none of the others test | Fine, but bundles parse+deliver into one task (t-9) and prompt+dispatch into one (t-7) | Correct 3-wave DAG |
| mvp (4t/2w) | Full, but concentrated — one task (t-3) alone carries c-1,c-2,c-3,c-5,c-6 | Detailed prose, but multiple independent behaviors packed into one task's contract paragraph | Coarsest by far — t-3 is debounce+diff+gating+dispatch+config in one module, t-4 is hook-install+session+script+notify in one | Correct but shows as two same-numbered "Wave 2" tracks (labeling only, not a DAG error) |
| verification (10t/3w) | Full, finest-grained mapping; only draft to note c-4's "never a tool call" half is already guaranteed by existing `decision.lua`, needing no new task | Strongest — contracts cite real signatures verified against source (`config.resolve({}).codriver.review_on_save`, `merge()`'s 3rd-arg-omitted default checked against the actual `session.lua:88` call site) | Finest; splits parse/render/notify-glue into three separate tasks along real module seams | Cleanest DAG: 7 truly independent wave-1 tasks, two correctly-scoped wave-2 tracks, one wave-3 task depending on both |

**Skeleton: verification.md.** It is the only draft whose contracts were written
with the actual function signatures in hand rather than plausible-sounding
ones, its wave-1 is the largest fully-independent batch (7 tasks), and its
coverage table makes a real, verified scope-reduction argument instead of
just listing task IDs.

## Merged plan

```
Wave 1
  t-1  Add review_on_save config toggle                                    [risk+mvp+verification]
       files:    lua/codriver/config.lua, tests/codriver/config_spec.lua
       covers:   c-5
       contract: config.resolve({}).codriver.review_on_save is false by default;
                 config.resolve({review_on_save=true}) resolves true;
                 config.resolve({review_on_save="x"}) raises naming review_on_save
                 (mirrors auto_start's boolean validation); an unknown key such as
                 `reviewOnSave` still raises the existing "unknown top-level option"
                 error.

  t-2  Per-buffer review snapshot store                                    [risk, finer split than verification's combined t-2]
       files:    lua/codriver/review/snapshot.lua, tests/codriver/review_snapshot_spec.lua
       covers:   c-3
       contract: advance(bufnr, lines) then get(bufnr) returns lines; after
                 advance(5, {...}) then clear(5), get(5) returns nil — a stale
                 snapshot must not survive a buffer wipe, or a bufnr recycled for a
                 different file would diff against the wrong file's last-reviewed
                 content; snapshots for two different bufnrs are independent.

  t-3  Line-hunk diff between snapshot and buffer                          [risk+verification, diff algorithm per disagreement below]
       files:    lua/codriver/review/diff.lua, tests/codriver/review_diff_spec.lua
       covers:   c-3
       contract: diff(bufnr, lines) returns nil/{} once advance(bufnr, lines) was
                 called with identical lines — an unmodified save must not
                 manufacture a hunk to review; changing one line of a 100-line
                 buffer without advancing yields a hunk scoped to that line, not
                 1..100; wraps vim.diff() rather than a hand-rolled line-compare
                 (see Disagreements).

  t-4  Save-coalescing debounce module                                     [verification, mirrors existing vendor mention-batching timer pattern]
       files:    lua/codriver/review/debounce.lua, tests/codriver/review_debounce_spec.lua
       covers:   c-6
       contract: 10 trigger() calls inside one injected-fake-timer window invoke
                 the callback exactly once, only after the timer fires; two calls
                 separated by a fired window produce two separate invocations;
                 trigger() never calls the callback synchronously.

  t-5  Review prompt builder                                               [verification]
       files:    lua/codriver/review/prompt.lua, tests/codriver/review_prompt_spec.lua
       covers:   c-1, c-3
       contract: prompt.build(bufname, hunks) names the buffer's path and lists
                 only the changed line range (e.g. 12-15), never the whole file;
                 output contains the literal `REVIEW <path>:<line>: <comment>`
                 instruction the parser in t-6 keys on.

  t-6  Anchored-comment transcript parser                                  [verification]
       files:    lua/codriver/review/parse.lua, tests/codriver/review_parse_spec.lua
       covers:   c-4
       contract: `REVIEW lua/foo.lua:12: consider renaming` parses to one
                 {file, line=12, text} entry; a non-REVIEW line is ignored; two
                 REVIEW lines for the same file at different lines yield two
                 entries; a non-numeric line field is skipped, not raised.

  t-7  Generalize hook settings install + publish review_on_save state     [risk+mvp+verification, converged independently]
       files:    lua/codriver/hook/claude_settings.lua, lua/codriver/hook/state.lua,
                 tests/codriver/hook_claude_settings_spec.lua, tests/codriver/hook_state_spec.lua
       covers:   c-4, c-5
       contract: merge(existing, command, "Stop") inserts into doc.hooks.Stop and
                 leaves an existing doc.hooks.PreToolUse array untouched; merge()
                 with the 3rd arg omitted still defaults to "PreToolUse" — the
                 existing `session.lua:88` call site (`install(path,
                 hook_command())`, 2 args) must not break; state.publish({...,
                 review_on_save=true}) round-trips through read()/probe();
                 review_on_save absent normalizes to nil like bash_allow/write_allow.

  t-8  Extmark review-comment renderer                                     [risk+verification, convergent file path tests/nvim/review_render_check.lua]
       files:    lua/codriver/review/render.lua, tests/nvim/review_render_check.lua
       covers:   c-4
       contract: render.show(bufnr, {{line=3,text="nit"}}) creates one extmark per
                 entry in codriver's own namespace as virtual text (never
                 nvim_buf_set_text or any Edit/Write-shaped API); a second
                 render.show() call clears the first call's extmarks before drawing
                 new ones; a line number past the buffer's end is clamped/skipped,
                 not raised, and a second valid comment in the same payload still
                 renders.

Wave 2 (depends t-6, t-8)
  t-9  Stop-hook receiver wiring parsed comments to render                 [verification skeleton + mvp idempotency graft]
       files:    lua/codriver/review/notify.lua, tests/nvim/review_notify_check.lua
       covers:   c-4
       contract: notify.received({comments={{file=<open buf>, line=2, text="x"}}})
                 produces exactly one extmark in that buffer; a comment for a file
                 with no matching loaded buffer (bufnr == -1) raises nothing and
                 adds no extmark; two comments for the same buffer arrive as one
                 render.show() call, not two; [mvp] once a review's comments have
                 been rendered, a second stray notify.received() for the same
                 pending review is a no-op — the pending marker is cleared after
                 the first successful render, so a duplicate Stop event never
                 double-renders or re-triggers.

Wave 2 (depends t-1, t-2, t-3, t-4, t-5)
  t-10 Wire BufWritePost review trigger into setup()                       [verification skeleton + risk send-failure graft]
       files:    lua/codriver/review/autosave.lua, lua/codriver/init.lua, tests/nvim/review_autosave_check.lua
       covers:   c-1, c-2, c-3, c-5, c-6
       contract: role=navigator + review_on_save=true + a changed buffer -> exactly
                 one send_to_terminal(text, {submit=true}) call; role=driver on the
                 same changed buffer -> zero calls; review_on_save=false (default)
                 -> zero calls regardless of role; 10 rapid :write calls inside the
                 debounce window -> exactly one call; a :write with no diff since
                 the last snapshot -> zero calls; [risk] when send_to_terminal
                 returns false (no terminal open, its own documented behavior), the
                 snapshot is NOT advanced — the next save's diff still includes the
                 dropped changes instead of the review being silently lost forever.

Wave 3 (depends t-7, t-9)
  t-11 Register Stop hook and verify end-to-end RPC render                 [verification]
       files:    scripts/codriver-review-hook.lua, lua/codriver/session.lua,
                 lua/codriver/init.lua, tests/nvim/review_hook_check.lua,
                 tests/nvim/hook_settings_check.lua
       covers:   c-4, c-5
       contract: running the Stop hook against a live state file with
                 role=navigator and review_on_save=true, on a transcript containing
                 a REVIEW line, produces exactly one extmark in the target buffer
                 via RPC; review_on_save=false -> zero extmarks; role=driver -> zero
                 extmarks; session.ensure_server() registers hooks.Stop pointing at
                 scripts/codriver-review-hook.lua alongside the existing
                 hooks.PreToolUse entry without clobbering either.
```

## Coverage

- c-1: t-5, t-10
- c-2: t-10
- c-3: t-2, t-3, t-5, t-10
- c-4: t-6, t-7, t-8, t-9, t-11 (the "never a proposed Edit/Write tool call" half
  is already guaranteed by the existing PreToolUse decision core in
  `lua/codriver/hook/decision.lua`, verified in-tree — no task needed for it)
- c-5: t-1, t-7, t-10, t-11
- c-6: t-4, t-10

11 tasks across 3 waves, 3 disagreements.

## Disagreements

**1. Diff implementation: hand-rolled line-compare vs `vim.diff()`.**
Risk and verification both spec a bespoke pure `hunks()`/`diff()` Lua function
and write tests defending against off-by-one anchor bugs (e.g. "reports the
inserted line at line 2, not line 1 or 3"). mvp instead has `review.flush()`
call `vim.diff()` — Neovim's built-in diff primitive — and never proposes a
custom algorithm. **Provisional default: `vim.diff()`** (mvp's choice), kept as
t-3's implementation detail. A hand-rolled line-diff is exactly the kind of
off-by-one-prone code the other two drafts felt the need to write defensive
tests against; a built-in, already-shipped-and-tested primitive removes that
whole failure class. This matters because c-4's anchor accuracy depends
entirely on the diff being right — the cheapest way to be right is to not
write the algorithm.

**2. Stop-hook gating mechanism: transcript-marker-only vs state-flag double-gate.**
Risk gates delivery purely on a "review-request marker" it expects the Stop
hook to find by re-parsing the transcript — no state.lua involvement. mvp
and verification both additionally publish a flag through `state.lua`
(mvp: a `pending_review{file, requested_at}` record; verification:
`review_on_save`) and gate the Stop hook on that flag *in addition to* the
transcript's REVIEW-line grammar. **Provisional default: the double-gate**
(verification's `review_on_save` state flag + t-6's literal `REVIEW
<path>:<line>:` grammar). A marker-only gate has a real, if narrow, false-positive
surface: an ordinary driver-mode chat reply that happens to contain a
`REVIEW path:line: text`-shaped line would misrender as a review comment
under risk's design. The double-gate also costs nothing new — `state.lua` is
already the established channel for hook-only toggles (`test_command`,
`bash_allow`, `write_allow`), so wiring `review_on_save` through it needs no
new plumbing, exactly as verification's own judgment call argues.

**3. Stop-hook re-fire idempotency: untested (risk, verification) vs
explicitly guarded (mvp).** mvp is the only draft that anticipates a second,
stray Stop event firing for the same turn and requires that it not re-render
(gated by clearing its `pending_review` flag immediately after the first
render). Neither risk's t-9 nor verification's t-9/t-11 contracts test this
case at all — both are silent on whether a Stop hook can fire more than once
per turn in this codebase. **Provisional default: adopt mvp's guard**, grafted
into merged t-9's contract (clear the pending marker after the first
successful render). This is a real robustness gap the other two lenses
simply didn't consider, not a stylistic difference — a double-render would
either duplicate extmarks or, worse, silently re-fire the RPC path against a
buffer that may have moved on. Whether Claude Code's Stop hook can in fact
fire twice per turn is unverified against the actual hook infrastructure and
should be confirmed during t-9's implementation, not assumed either way.
