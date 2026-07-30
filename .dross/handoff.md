## Auto-snapshot
- captured: 2026-07-30 09:27 UTC (resumed — nothing landed since 09:15)
- branch: (no git)
- dirty: (no git)
- phase: (none) · v0.1.0.0
- next: /dross-init or /dross-onboard — project.toml is incomplete

## Mental thread

Mid-`/dross-init` on a greenfield Neovim plugin. Vision, market scan, and
differentiators are captured in `.dross/project.toml`. Stopped at **step 3,
stack choice**.

### What this project is

A Neovim plugin that keeps Claude Code beside you as a **navigator** —
watching, advising, writing only when you hand over the keyboard. Origin
framing from the user: *"trying to take back my code"* + *"pair programming
like with another human"* — sometimes "finish this template for me", sometimes
"give me ideas while I write".

### Decisions locked so far

- **Name**: DEFERRED. User wants to pick it once specs are clearer. `project.name`
  is still `""` — must be filled before init completes.
- **Foundation**: FORK / VENDOR `coder/claudecode.nvim` (MIT, 2.9k stars, actively
  maintained, pure Lua). Own the protocol code outright rather than depend on it,
  so internals can be reached for role-switching and read-only mode. User chose
  this over "depend on it" after being shown the maintenance cost.
- **Description / core value / audience / non-goals / differentiators**: all written
  to `project.toml`. Enforced read-only was folded INTO the turn-taking
  differentiator rather than kept as a fourth.

### Key technical findings (already researched — don't redo)

- Claude Code IDE protocol: editor runs a WebSocket server, writes
  `~/.claude/ide/<port>.lock` (pid, workspaceFolders, ideName, transport,
  authToken), Claude Code connects as MCP client, authenticates with header
  `x-claude-code-ide-authorization: <token>`.
- IDE exposes 12 tools: `openFile`, `openDiff` (blocks until accept/reject),
  `getCurrentSelection`, `getLatestSelection`, `getOpenEditors`,
  `getWorkspaceFolders`, `getDiagnostics`, `checkDocumentDirty`, `saveDocument`,
  `close_tab`, `closeAllDiffTabs`, `executeCode`.
- IDE→Claude notifications: `selection_changed`, `at_mentioned`.
- Because it's a socket, Claude Code does NOT need to be a child of nvim —
  separate tmux window/session works fine.
- Enforcement for read-only navigator mode (3 options, ascending elegance):
  1. `--permission-mode plan`, 2. `permissions.deny` on Edit/Write in
  settings.json, 3. **`PreToolUse` hook** reading plugin role state — flips at
  runtime, no session restart. Docs quote that justifies it: *"Permission rules
  are enforced by Claude Code, not by the model."*
- claudecode.nvim already has `provider = "external"` and `provider = "none"`
  for tmux — the control-surface part is largely solved upstream.

### Where we stopped

Was about to propose the stack. Established already: Lua is the only sane
choice; the real open question is the **test toolchain**. Was mid-investigation
of what claudecode.nvim itself uses — its repo root has `.luacheckrc`,
`.stylua.toml`, `treefmt.toml`, `mise.toml`, `tests/`, so the likely answer is
**busted + luacheck + stylua + mise**, matching upstream to reduce vendoring
friction. `raw.githubusercontent.com` is blocked by WebFetch — read
`DEVELOPMENT.md` via the GitHub API contents endpoint or the blob URL instead.

### Next actions, in order

1. Confirm upstream's test/lint/format toolchain, propose stack, lock choices
   with `why` into `[[stack.locked]]`.
2. Step 4 remote — `[remote]` is pre-seeded (forgejo, git.rivil.co.uk,
   FORGEJO_TOKEN). Still needs `url`, `public`, maybe `reviewers`.
3. Step 5 rules → 6 scaffold (vendor claudecode.nvim) → 7 runtime capture →
   8 verification → 9 git init + first commit → 9.5 telemetry → 10 wrap.
4. Circle back to the project NAME before wrapping.

### Open loops

- Project name unresolved.
