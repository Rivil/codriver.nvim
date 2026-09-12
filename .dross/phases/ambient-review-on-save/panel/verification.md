Phase ambient-review-on-save — 10 tasks across 3 waves

Wave 1
  t-1  Add review_on_save config toggle
       files:    lua/codriver/config.lua, tests/codriver/config_spec.lua
       covers:   c-5
       contract: config.resolve({}).codriver.review_on_save is false by default; config.resolve({review_on_save=true}) resolves true; config.resolve({review_on_save="x"}) raises naming review_on_save (mirrors auto_start's boolean validation)

  t-2  Add per-buffer review snapshot/diff module
       files:    lua/codriver/review/snapshot.lua, tests/codriver/review_snapshot_spec.lua
       covers:   c-3
       contract: diff(bufnr, lines) returns nil once advance(bufnr, lines) was called with identical lines; changing one line of a 100-line buffer without advancing yields a diff scoped to that line, not 1..100; snapshots for two different bufnrs are independent

  t-3  Add save-coalescing debounce module
       files:    lua/codriver/review/debounce.lua, tests/codriver/review_debounce_spec.lua
       covers:   c-6
       contract: 10 trigger() calls inside one injected-fake-timer window invoke the callback exactly once, only after the timer fires; two calls separated by a fired window produce two separate callback invocations; trigger() never calls the callback synchronously

  t-4  Add review prompt builder
       files:    lua/codriver/review/prompt.lua, tests/codriver/review_prompt_spec.lua
       covers:   c-1, c-3
       contract: prompt.build(bufname, hunks) names the buffer's path and lists only the changed line range (e.g. 12-15), never the whole file; output contains the literal `REVIEW <path>:<line>: <comment>` instruction the parser in t-5 keys on

  t-5  Add anchored-comment transcript parser
       files:    lua/codriver/review/parse.lua, tests/codriver/review_parse_spec.lua
       covers:   c-4
       contract: a transcript line `REVIEW lua/foo.lua:12: consider renaming` parses to one {file, line=12, text} entry; a non-REVIEW line is ignored; two REVIEW lines for the same file at different lines yield two entries; a non-numeric line field is skipped, not raised

  t-6  Generalize hook settings install + publish review_on_save state
       files:    lua/codriver/hook/claude_settings.lua, lua/codriver/hook/state.lua, tests/codriver/hook_claude_settings_spec.lua, tests/codriver/hook_state_spec.lua
       covers:   c-4, c-5
       contract: merge(existing, command, "Stop") inserts into doc.hooks.Stop and leaves an existing doc.hooks.PreToolUse array untouched; merge() with the 3rd arg omitted still defaults to "PreToolUse" (no existing call site breaks); state.publish({review_on_save=true}) round-trips through read()/probe(); review_on_save absent normalizes to nil like bash_allow/write_allow

  t-7  Add extmark review-comment renderer
       files:    lua/codriver/review/render.lua, tests/nvim/review_render_check.lua
       covers:   c-4
       contract: render.show(bufnr, {{line=3,text="nit"}}) creates an extmark in codriver's own namespace at line 3 whose virt_text contains "nit"; a second render.show() call clears the first call's extmarks before drawing new ones; a comment line number past the buffer's end is clamped instead of raising nvim_buf_set_extmark's range error

Wave 2 (depends t-5, t-7)
  t-8  Add Stop-hook receiver wiring parsed comments to render
       files:    lua/codriver/review/notify.lua, tests/nvim/review_notify_check.lua
       covers:   c-4
       contract: notify.received({comments={{file=<path of an open scratch buffer>, line=2, text="x"}}}) produces exactly one extmark in that buffer; a comment for a file with no matching loaded buffer (vim.fn.bufnr == -1) raises nothing and adds no extmark; two comments for the same buffer arrive as one render.show() call, not two

Wave 2 (depends t-1, t-2, t-3, t-4)
  t-9  Wire BufWritePost review trigger into setup()
       files:    lua/codriver/review/autosave.lua, lua/codriver/init.lua, tests/nvim/review_autosave_check.lua
       covers:   c-1, c-2, c-3, c-5, c-6
       contract: role=navigator + review_on_save=true + a changed buffer -> exactly one send_to_terminal(text, {submit=true}) call; role=driver on the same changed buffer -> zero calls; review_on_save=false (default) -> zero calls regardless of role; 10 rapid :write calls inside the debounce window -> exactly one call; a :write with no diff since the last snapshot -> zero calls

Wave 3 (depends t-6, t-8)
  t-10 Register Stop hook and verify end-to-end RPC render
       files:    scripts/codriver-review-hook.lua, lua/codriver/session.lua, lua/codriver/init.lua, tests/nvim/review_hook_check.lua, tests/nvim/hook_settings_check.lua
       covers:   c-4, c-5
       contract: running the Stop hook against a live state file with role=navigator and review_on_save=true, on a transcript containing a REVIEW line, produces exactly one extmark in the target buffer of the running Neovim instance via RPC; the same run with review_on_save=false produces zero extmarks; the same run with role=driver produces zero extmarks; session.ensure_server() registers a hooks.Stop entry pointing at scripts/codriver-review-hook.lua alongside the existing hooks.PreToolUse entry, and neither clobbers the other

## Coverage

- c-1: t-4, t-9
- c-2: t-9
- c-3: t-2, t-4, t-7, t-9
- c-4: t-5, t-6, t-7, t-8, t-10 (the "never as an Edit/Write tool call" half of c-4 is already guaranteed by the existing PreToolUse decision core in lua/codriver/hook/decision.lua — no new task needed for it, since a plain-text Stop-hook reply was never a tool call to begin with)
- c-5: t-1, t-6, t-9, t-10
- c-6: t-3, t-9

## Judgment calls

- Per-buffer snapshot state lives in-memory in lua/codriver/review/snapshot.lua, keyed by bufnr, with the first-ever diff for a buffer treating the whole buffer as changed. Rejected an attach-time-captured snapshot (on BufEnter) — that adds a second lifecycle event to reason about just to avoid one rare cold-start full-file review, which no criterion asks for.
- Chose a fixed literal reply format, `REVIEW <path>:<line>: <comment>`, embedded as an instruction in the outbound prompt (t-4) and matched literally by the parser (t-5), over asking Claude to reply in JSON. A grep-able text anchor keeps the Stop-hook parser a single Lua pattern with no JSON-in-transcript extraction risk, and it is the smallest thing that can anchor a comment to a line.
- Split the Stop hook into its own script (scripts/codriver-review-hook.lua) rather than extending scripts/codriver-hook.lua to dispatch on hook_event_name. Rejected merging them: the PreToolUse script's fail-closed "exactly one JSON permission document or nothing" contract is a hard safety property, and giving it a second, unrelated event type to branch on is new failure surface for no benefit.
- Made Stop-hook *registration* unconditional (installed on every arm(), matching how PreToolUse is already always installed) and gated the *behavior* behind a `review_on_save` flag published through state.lua/probe(), rather than threading an enable flag through session.lua's install call. state.lua is already the established channel for toggles that only matter to the out-of-process hook (test_command, bash_allow, write_allow) — reusing it needs no new plumbing through session.lua's arm().
- render.show() wipes and redraws a buffer's entire comment set on every call (one namespace, clear-then-draw) instead of diffing extmarks incrementally. Incremental extmark diffing is unwarranted complexity here: c-3 already guarantees each review's comment set is scoped to a small just-changed hunk, so there is never a large stable set worth preserving across redraws.
