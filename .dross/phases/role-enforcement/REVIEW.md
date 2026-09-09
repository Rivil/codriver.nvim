# Plan Review — role-enforcement

Reviewed: 2026-07-31 (second pass, post-amendment)
Plan: 14 tasks across 5 waves

## BLOCKING

- [locked-decision] `test_command` is validated but never transported to the process that needs it.
  The `bash_policy` lock puts "a codriver-configured test command" in the allowlist. t-2 matches
  against it (`with test_command 'mise run test'`), t-6 accepts it as a top-level codriver key, and
  t-12 asserts end-to-end that "the configured test_command is denied" is a failure. But nothing
  carries the value across the process boundary: t-1's record is schema + owner pid + role, t-6's
  channel is exactly `{ state_file, nvim_address }`, and t-7's entrypoint runs under
  `nvim --clean -l` with no user config on runtimepath and no meaningful way to reach codriver's
  config. t-5's `decide(payload, session)` has no field it could read it from. c-5's "running the
  project's test command" cannot pass as planned.
  Suggestion: assign the transport to a task and say so in its contract — either t-1's record grows
  the field (published by t-8 alongside the role, which makes it live-reloadable for free) or t-6's
  channel grows a third key. Whichever, t-5's `session` argument needs to name it and t-2's caller
  needs a contract item that it is threaded rather than hardcoded.

- [antipattern] t-9's headless check will arm enforcement in this repository's own `.claude/`.
  Its contract asserts "the write path is not `vim.fn.getcwd()` under the default configuration" as
  the failure mode, and `mise.toml`'s test-nvim task runs every check as
  `nvim --clean --headless -l "$f"` from the repo root — so `getcwd()` is
  `/Users/rivil/Development/codriver`. A check that drives a real `session.start()` (contract item 1
  records call order from it) writes a codriver PreToolUse entry into the developer's live
  `.claude/settings.local.json`. `tests/nvim/harness.lua` sandboxes HOME and CLAUDE_CONFIG_DIR
  (harness.lua:19-20, 175-224) but never cwd, so the existing sandbox does not cover this. Because
  the entry "deliberately survives stop" and this repo's own dev loop is Neovim + codriver, a
  routine `mise run test` leaves the developer's next Claude Code session gated. t-3 guards this
  exact hazard explicitly (item 10: "install(<temp root>) writes anything under this repository's
  own .claude/") and t-10 says "in a temp project dir" — t-9 has neither, which reads as an
  oversight rather than a decision.
  Suggestion: add a contract item to t-9 pinning that the check operates in a temp project dir and
  that nothing under the repository's own `.claude/` is modified across the run — mirroring t-3's
  item 10 wording.

## FLAG

- [wave order] t-6's dependency on t-1 is now vestigial and costs a wave.
  The amendment removed path/address computation from `resolve` — it receives the channel as a
  parameter, and the contract item "if resolve computes the channel itself rather than receiving it"
  actively forbids it touching `vim.fn.stdpath`. Neither t-6's files (`config.lua`,
  `config_spec.lua`) nor any of its seven contract items need a symbol from t-1. Dropping t-6 to
  wave 1 pulls t-8 to wave 2, t-9 to wave 3, and the five checks to wave 4 — one wave off the
  critical path, and it dissolves wave 4's single-task serialization point.
  Suggestion: drop `depends_on = ["t-1"]` from t-6 and move it to wave 1. (Also drop `t-6` from
  t-9's depends_on — it is implied transitively through t-8 and adds nothing.)

- [granularity] t-3 is a split candidate that got larger, not smaller, in the amendment.
  It now owns a hand-written deterministic JSON serializer (sorted keys, fixed indent, known-array-
  path table), merge semantics, stale-entry replacement, third-party-hook preservation, and an
  atomic read-merge-write — across 3 files, 3 layers (pure transform / pure serializer / filesystem)
  and 10 contract items. The serializer is a self-contained unit with its own failure surface and no
  dependency on the settings schema beyond one table.
  Suggestion: split `encode(doc)` + its array-path table into its own wave-1 task carrying the
  determinism and array-ness contract items; leave merge + install in t-3.

- [test contract] t-3's array-ness preservation has an unpinned hole at unknown paths.
  The round trip is asserted for "empty allow, empty hooks, and a document with no permissions key
  at all" — all known paths. A settings file carrying an empty array at a path the encoder's table
  does not list (`permissions.deny`, `permissions.ask`, `permissions.additionalDirectories`, the
  nested `hooks.<Event>[].hooks[]`, or any key a future Claude Code version adds) round-trips to
  `{}`. That is the same silent-corruption failure the hand-written serializer was written to
  prevent, just displaced from `allow` to everything else — and the plan's own framing ("Claude Code
  reads a malformed permissions block") applies verbatim.
  Suggestion: add a contract item fixing the behaviour for an empty array at an unlisted path —
  either preserved as an array by construction, or install refuses and names the path, the way it
  already refuses malformed JSON. Silently emitting `{}` should not be a passing outcome.

- [test contract] t-4's coalescing item likely invalidates t-4's own file placement.
  The task rests on "busted-testable because vim.notify is the one API the existing minimal stub
  already carries" — but "ten denials inside one second produce ten notifications" cannot be
  implemented without a clock or timer (`vim.uv.now`, `vim.defer_fn`, `vim.schedule`), none of which
  that premise covers. This is a second-order consequence of the accepted "needs a clock in a busted
  spec" flag: it is not only that the test is awkward, it is that satisfying the contract moves
  `notify.lua` off the stub and the spec into `tests/nvim/`, which `mise.toml`'s test-nvim guard
  then requires be renamed `*_check.lua`.
  Suggestion: if the coalescing item stays, decide now which lane t-4 lives in and name the file
  accordingly, or make the window injectable so the spec supplies its own clock and the busted
  placement survives.

## NOTE

- [coverage] Complete. c-1: t-3/t-6/t-9/t-10; c-2: t-5/t-7/t-11; c-3: t-5/t-7/t-11; c-4: t-2/t-12;
  c-5: t-2/t-5/t-7/t-12; c-6: t-1/t-6/t-7/t-8/t-13; c-7: t-1/t-5/t-7/t-13; c-8: t-4/t-7/t-14.

- [antipattern] No dangling file references. `mise.toml`, `tests/nvim/harness.lua`,
  `lua/codriver/config.lua`, `init.lua` and `session.lua` all exist; every `lua/codriver/hook/*` and
  `scripts/codriver-hook.lua` path is created by the task that first names it. t-6's signature change
  is safe standalone: `config.resolve` has exactly one caller (lua/codriver/init.lua:172), owned by
  t-8, and t-6's own contract makes `resolve(opts, nil)` well-defined in the interim.

- [forbidden actions] Clean against both project rules. No task touches `lua/codriver/vendor/`
  (r-02) — t-9 explicitly declines to reproduce the vendored private `build_config` chain and cites
  r-02 as the reason — and t-6 explicitly forbids reading `.dross/project.toml`, keeping r-01's
  hand-edit-only invariant out of the plugin's runtime path entirely. No global
  `~/.claude/dross/rules.toml` exists.

- [test contract] Contract quality is uniformly high: across 14 tasks and ~100 items there is no
  "tests pass", no "covered by integration", no "existing tests verify". Every item names the
  observable that breaks and why it matters. t-7's "an emitted permissionDecision 'allow'
  auto-approves every tool the user never consented to, converting codriver from a restriction into
  a blanket permission grant" is the sharpest item in the plan and catches a failure that would
  otherwise ship as a feature.

- [granularity] The busted/headless lane split is correct throughout and matches the convention
  `mise.toml`'s test-nvim task actively enforces: pure modules (t-2, t-4, t-5, t-6) get
  `*_spec.lua`; anything needing `vim.fn`/`vim.uv`/a real process (t-1, t-3's install half, t-8,
  t-10..t-14) gets `*_check.lua`. t-1's freeze-at-load contract cites a real existing hazard the
  harness already guards for the vendored `lock_dir` — the plan is reasoning from this repo, not
  from a template.

- [granularity] t-7 remains the plan's bottleneck by choice: wave 3, 4 files, 6 criteria, 11
  contract items, and sole owner of `harness.run_hook`, which all five wave-5 checks consume. The
  centralization argument is sound; the schedule risk is that a slip there stalls a third of the
  plan. Recording, not re-litigating.

- [granularity] `scripts/` is added to the syntax and luacheck globs but not to typecheck —
  `.luarc.json` scopes lua-language-server to `lua/codriver`. Probably right for an `nvim -l` script
  with a different global set; noted only so the omission is deliberate.

## Summary

Two blocking gaps in an otherwise strong plan: the allowlisted test command has no owner for its
trip from Neovim config into the hook subprocess, and t-9's headless check as contracted would write
codriver's own enforcement hook into this repository's live `.claude/settings.local.json`.
