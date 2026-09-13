```
Phase ambient-review-on-save — 9 tasks across 3 waves

Wave 1
  t-1  Add review_on_save opt-in config toggle
       files:    lua/codriver/config.lua, tests/codriver/config_spec.lua
       covers:   c-5
       contract: setup({review_on_save = "yes"}) raises (must be boolean); omitting the
                 key resolves review_on_save = false; an unknown key such as
                 `reviewOnSave` still raises the existing "unknown top-level option"
                 error, proving the new key didn't loosen validation.

  t-2  Per-buffer review snapshot store
       files:    lua/codriver/review/snapshot.lua, tests/codriver/review_snapshot_spec.lua
       covers:   c-3
       contract: after advance(5, {...}) then clear(5), get(5) returns nil — a stale
                 snapshot must not survive a buffer wipe, or a bufnr recycled for a
                 different file would diff against the wrong file's last-reviewed
                 content.

  t-3  Line-hunk diff between snapshot and buffer
       files:    lua/codriver/review/diff.lua, tests/codriver/review_diff_spec.lua
       covers:   c-3
       contract: hunks({"a","b","c"}, {"a","b","c"}) returns {} — an unmodified save
                 must not manufacture a hunk to review; hunks({"a","b"}, {"a","x","b"})
                 reports the inserted line at line 2, not line 1 or 3, so the anchor
                 c-4 renders against is the actually-changed line.

  t-4  Generalize claude_settings hook merge for a second event
       files:    lua/codriver/hook/claude_settings.lua, tests/codriver/hook_claude_settings_spec.lua
       covers:   c-4
       contract: installing a Stop hook into a settings file that already has
                 codriver's PreToolUse entry leaves the PreToolUse entry untouched and
                 adds hooks.Stop alongside it — proving the generalization didn't
                 collapse the two event arrays into one or let a re-install of one
                 event clobber the other's dedup.

  t-5  Extmark renderer for review comments
       files:    lua/codriver/hook/review.lua, tests/nvim/review_render_check.lua
       covers:   c-4
       contract: a payload with a line number past the buffer's last line does not
                 error and does not crash the RPC call — that comment is skipped
                 while a second, valid comment in the same payload still renders as
                 virtual text; a payload naming a buffer that isn't open is a no-op,
                 not an error.

Wave 2 (depends t-1..t-5)
  t-6  Debounced, role-gated BufWritePost trigger
       files:    lua/codriver/review/trigger.lua, tests/codriver/review_trigger_spec.lua
       covers:   c-1, c-2, c-6
       depends:  t-1
       contract: five notify_write(3) calls 100ms apart (format-on-save burst) with a
                 500ms quiet window fire the callback exactly once, not five times
                 (c-6); if role.set("driver") happens after notify_write but before
                 the quiet window elapses, the callback never fires — the gate is
                 checked at fire time, not schedule time (c-2), which a check reading
                 role only when notify_write was first called would get wrong.

  t-7  Review request composition and dispatch
       files:    lua/codriver/review/request.lua, tests/codriver/review_request_spec.lua
       covers:   c-1, c-3
       depends:  t-2, t-3
       contract: when send_to_terminal returns false (no terminal open, per its own
                 documented behavior), the snapshot is NOT advanced — the next save's
                 diff still includes the dropped changes, instead of the review being
                 silently lost forever; when the diff is empty, send_to_terminal is
                 never called at all.

Wave 3 (depends t-6, t-7, and wave 1)
  t-8  Wire the review autocmd into setup()
       files:    lua/codriver/init.lua, tests/codriver/init_spec.lua
       covers:   c-1, c-2, c-5, c-6
       depends:  t-6, t-7
       contract: with review_on_save = false (the default), calling setup() and
                 firing a fake BufWritePost never touches trigger.notify_write —
                 proving c-5's off-by-default isn't just a config default that a
                 wired-up autocmd ignores; calling setup() twice with
                 review_on_save = true and firing one BufWritePost still results in
                 exactly one call to trigger.notify_write, not two, matching the
                 existing "survives being set up twice" guarantee enforcement already
                 has.

  t-9  Stop-hook: parse and deliver Claude's review reply
       files:    scripts/codriver-review-hook.lua, lua/codriver/session.lua,
                 tests/nvim/hook_review_install_check.lua
       covers:   c-4
       depends:  t-4, t-5, t-7
       contract: a transcript for a normal (non-review) turn produces zero RPC calls
                 to codriver.hook.review — the review-request marker, not "any Stop
                 event", gates delivery, so a plain :CodriverSend turn never gets
                 misrendered as a review; a transcript with no comments in the
                 expected anchor format, or a malformed one, exits 0 without RPC-ing
                 garbage into the renderer (fails closed on the parse, matching
                 codriver-hook.lua's own fail-closed contract).
```

## Coverage

- c-1 (save triggers review as navigator): t-6, t-7, t-8
- c-2 (no review action as driver): t-6, t-8
- c-3 (scoped to changes since last review): t-2, t-3, t-7
- c-4 (virtual-text-only rendering, never a tool call): t-4, t-5, t-9
- c-5 (off by default, opt-in): t-1, t-8
- c-6 (rapid saves coalesce): t-6, t-8

## Judgment calls

- Split debounce/gating (t-6) from diff/dispatch (t-7) into two modules rather than
  one `review/autosave.lua` — the c-2 fire-time-vs-schedule-time race and c-6's
  coalescing are independently testable this way; a combined module would make a
  prompt-building bug and a debounce bug produce the same kind of test failure.
- Snapshot advances only when `send_to_terminal` returns true (t-7), not
  unconditionally after a review "fires" — rejected always-advance because a
  terminal-not-open failure (a documented, non-error return from the locked
  delivery mechanism) would otherwise silently and permanently drop that diff
  from every future review.
- Generalized `claude_settings.merge`/`install` to take an event name (t-4) instead
  of adding a second, parallel read-merge-write path for the Stop hook — two
  independent writers to the same settings file race each other and duplicate the
  array-type-path/dedup logic that only needs to be correct once.
- Introduced a review-request marker embedded in the prompt (t-7) as the signal
  the Stop hook (t-9) uses to decide a turn was a review — rejected treating every
  Stop event as a review reply, since c-4 requires review comments never look like
  a proposed edit, and misfiring on an ordinary `:CodriverSend` turn would render
  arbitrary chat text as false anchored comments.
- Kept diffing (t-3) as its own module rather than folding hunk computation into
  the snapshot store (t-2) — hunk-anchor correctness (what c-4 renders against) and
  buffer-lifecycle correctness (what c-3's snapshot risk is about) are different
  failure modes and deserve separate test files rather than one shared one.
