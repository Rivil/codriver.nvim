Phase ambient-review-on-save — 4 tasks across 2 waves

Wave 1
  t-1  Define review-reply contract: anchor format + pending flag
       files:    lua/codriver/review/format.lua, lua/codriver/hook/state.lua
       covers:   c-4
       contract: format.parse() extracts {line, text} entries from a reply body containing
                 lines like "L42: <comment>" and ignores prose lines without the anchor
                 prefix — if the pattern is too greedy, an ordinary sentence starting with a
                 capital L and a number gets mis-parsed into a phantom comment; format
                 .instructions() is a fixed string embedded verbatim in outgoing prompts —
                 if state.lua's publish()/read() round-trip drops the new pending_review field
                 (file, requested_at) the way it already round-trips test_command, the
                 Stop-hook task has nothing to gate on and c-4 fires on unrelated turns.

  t-2  Render review comments as buffer virtual text
       files:    lua/codriver/review/render.lua
       covers:   c-4
       contract: render.show(bufnr, comments) places one extmark per {line, text} entry in a
                 dedicated "codriver_review" namespace as virtual text — if it used
                 nvim_buf_set_text or any Edit/Write-shaped API instead of extmarks, c-4's
                 "never a proposed Edit/Write tool call" is violated; render.show() clears
                 that namespace before adding new marks, so a second review's comments don't
                 accumulate on top of the first's stale ones — verified in a headless nvim
                 check that asserts the buffer's extmark count after two successive calls.

Wave 2 (depends t-1)
  t-3  Debounced diff-scoped review send, gated on role + opt-in
       files:    lua/codriver/config.lua, lua/codriver/init.lua, lua/codriver/review/init.lua
       covers:   c-1, c-2, c-3, c-5, c-6
       contract: config.resolve() rejects a non-boolean review_on_save and defaults it to
                 false — config_spec's existing "unknown top-level option" and "wrong type"
                 tests extend to this key, and any project that never sets it gets zero
                 autocmds; the BufWritePost callback returns immediately when
                 role.is_navigator() is false — c-2's "no review action" fails if a driver-mode
                 save still calls review.schedule(); review.schedule(bufnr) restarts a
                 per-buffer vim.uv timer on every call rather than queuing one, so 10 saves in
                 200ms produce exactly 1 send after the quiet period, not 10 — c-6's coalescing
                 fails if the timer isn't cancelled and replaced; review.flush(bufnr) diffs the
                 current buffer against the stored per-buffer snapshot (vim.diff), not the
                 whole file and not a git ref — if the snapshot isn't advanced to the
                 just-sent content after send, the next save's diff re-includes lines Claude
                 already reviewed, failing c-3; flush() calls
                 vendor.terminal.send_to_terminal(prompt, {submit = true}) and never blocks
                 waiting on a reply.

Wave 2 (depends t-1, t-2)
  t-4  Stop hook: parse pending review reply and render it
       files:    lua/codriver/hook/claude_settings.lua, lua/codriver/session.lua,
                 scripts/codriver-review-hook.lua, lua/codriver/hook/review_notify.lua
       covers:   c-4
       contract: claude_settings.merge() takes an event name and can install a Stop entry
                 alongside an existing PreToolUse entry without deleting it — the existing
                 hook_claude_settings_spec's "survives being installed twice" case extended to
                 two different events must show both entries present in the encoded doc;
                 scripts/codriver-review-hook.lua exits 0 with no RPC attempt when
                 state.read() shows no pending_review — a Stop hook firing after an ordinary
                 driver-mode turn must never call review_notify.render(), or c-4 renders
                 comments on an unrelated reply; review_notify.render(payload) resolves
                 payload.file to a bufnr and clears pending_review from state after rendering
                 — a second stray Stop event for the same turn must not re-render.

## Coverage
- c-1: t-3
- c-2: t-3
- c-3: t-3
- c-4: t-1, t-2, t-4
- c-5: t-3
- c-6: t-3

## Judgment calls
- Config shape: `review_on_save` is a plain boolean (default false), not a table like
  bash_allow/write_allow. Rejected a table shape (e.g. `{ patterns = {...} }`) — no criterion
  asks for scoping which files trigger review, so a bare toggle is the smallest thing that
  satisfies c-5's "opt-in, off by default" without inventing an unused option surface.
- Stop-hook install is unconditional, not gated on `review_on_save`. Rejected making
  session.lua's `arm()` read `review_on_save` before installing the Stop hook — that needs
  session.lua to see init.lua's resolved config, and init.lua already requires session.lua, so
  the reverse require would be circular. Opt-in is instead enforced entirely on the send side
  (t-3 never publishes pending_review, never sends a prompt, unless the toggle is on) and the
  Stop hook subprocess is a no-op whenever pending_review is absent, so the unconditional
  install has no observable effect for a project that never opts in.
- First save on a buffer with no prior snapshot diffs against an empty string (the whole
  buffer counts as "changed"), rather than adding a separate "arm on buffer open" task to seed
  a snapshot before the first edit. Rejected the extra task — no criterion requires the very
  first save to be silent, and the per-buffer snapshot advancing after that first send still
  satisfies c-3 for every save after it.
- format.lua and render.lua are split into a new lua/codriver/review/ subdirectory with
  review/init.lua as the send-side orchestrator, mirroring the vendor/claudecode/init.lua
  package-root pattern already in this codebase. Rejected flattening everything into one
  lua/codriver/review.lua — the parse/render pieces have no vim-API dependency on the
  orchestrator and are reused independently by the Stop-hook subprocess (t-4), so collapsing
  them would force t-3 and t-4 to share one file with no wave boundary between them.
