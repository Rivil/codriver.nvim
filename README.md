# codriver.nvim

Claude Code as a **navigator**, not an author.

You keep writing the code and holding the mental model. Claude sits beside you,
watches every line, and advises — and only writes when you explicitly hand over
the keyboard.

> **Status: early.** Sessions work end to end — start one and Claude runs in a
> terminal already wired to your Neovim, reading your unsaved buffer and visual
> selection. The features codriver exists for — turn-taking enforcement, ambient
> review on save, dross task binding — are **not implemented yet**. Until they
> are, this is a `:Codriver*`-namespaced build of the vendored protocol layer.

## Why

Agent-first tooling hands you a wall of generated diff to review. That is a bad
trade: you end up owning code you did not write and do not have a model of.
Codriver inverts it — the review flows human → agent.

Three things it does that other Neovim AI plugins do not:

- **Turn-taking is first-class.** Explicit driver/navigator roles with a
  deliberate handoff, enforced rather than prompted. In navigator mode Claude's
  Edit/Write capability is withdrawn at the harness level, so the role cannot
  drift. Every competitor is stateless about who holds the keyboard.
- **dross-native task splitting.** The pairing session binds to a real dross
  phase and task graph; you and Claude split tracked work items and the plugin
  knows which are whose.
- **Ambient review on save.** Claude comments on what you just wrote as virtual
  text, without proposing edits.

## Non-goals

- Not an autonomous agent runner. No human at the keyboard, nothing happens.
- Not a Copilot-style inline completer.
- Neovim only — no portability abstraction layer.

## Requirements

- Neovim >= 0.11.0 (the plugin refuses to load below that; the pinned dev
  toolchain is 0.12.3)
- The [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) on
  `$PATH` as `claude`, or pointed at by `claudecode.terminal_cmd`

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Rivil/codriver.nvim",
  opts = {},
}
```

`setup()` is what registers the commands — nothing is registered at load time.

### Options

Codriver's own options sit at the top level; the vendored layer's options are
nested under `claudecode`. An unknown top-level key is an error rather than a
silent no-op.

```lua
require("codriver").setup({
  -- Open a session when setup() runs. Off by default: codriver's premise is
  -- that nothing happens without a human at the keyboard, and auto-start would
  -- open a server and write a lockfile on every nvim launch.
  auto_start = false,

  -- Passed through to the vendored claudecode layer.
  claudecode = {
    terminal = { provider = "auto" },
    -- track_selection = true,  -- Claude reading your selection depends on this
  },

  -- Exempted from the read-only Bash allowlist by exact match only — never as
  -- a prefix, and never by any of the shell-substring games that would let a
  -- prefix match slip something else through. Lets navigator mode run your
  -- own test suite without opening up the allowlist itself.
  test_command = "mise run test",

  -- Extends the read-only Bash allowlist beyond its hardcoded defaults
  -- (command heads like `rg`/`git`/`ls`, and git subcommands like `status`).
  -- Additive only — this can never shrink or replace the built-in floor, only
  -- add to it. Every entry must be a non-empty string, checked at setup()
  -- time: a malformed value errors immediately naming the bad field, rather
  -- than failing silently inside the PreToolUse hook.
  bash_allow = {
    heads = { "jq" },
    git_subcommands = { "stash" },
  },
})
```

Run `:checkhealth codriver` to see the effective Bash allowlist — hardcoded
defaults plus any `bash_allow` additions.

## Usage

Start a session with `:CodriverStart` — it brings the server up, then opens
Claude in a terminal already connected to this Neovim instance. You set no
environment variables, port, or lockfile path by hand.

| Command                                     | What it does                                          |
| ------------------------------------------- | ----------------------------------------------------- |
| `:CodriverStart` / `:CodriverStop`          | Open / tear down the session                          |
| `:CodriverStatus`                           | One line: listening, and whether Claude has connected |
| `:Codriver` / `:CodriverFocus`              | Toggle / smart-focus the Claude terminal              |
| `:CodriverOpen` / `:CodriverClose`          | Show / hide the terminal window                       |
| `:CodriverSend`                             | Send the visual selection as an at-mention            |
| `:CodriverAdd` / `:CodriverTreeAdd`         | Add a file or tree selection to context               |
| `:CodriverSendText`                         | Send text to the terminal and submit it               |
| `:CodriverDiffAccept` / `:CodriverDiffDeny` | Accept / reject the current proposed diff             |
| `:CodriverCloseAllDiffs`                    | Close pending diffs, leaving accepted ones            |
| `:CodriverSelectModel`                      | Pick a model and open the terminal with it            |

`:CodriverStatus` reports listening and connected as two distinguishable
states — a server that is up with nothing attached never reads as "Claude
attached". For the detailed view (port, lockfile path, connected client count,
toolchain) run `:checkhealth codriver`.

Running `:CodriverStart` again while a session is live reports the existing
session rather than erroring.

## Architecture

Feature-by-feature map with symbol links: [ARCHITECTURE.md](ARCHITECTURE.md).

The Claude Code IDE protocol (WebSocket server, lockfile discovery, MCP tools)
is **vendored** from [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim)
(MIT) rather than depended on, because role switching needs to reach internals
that upstream does not expose.

Vendored code lives under `lua/codriver/vendor/claudecode/` and is upstream-identical
except that every Lua module path is re-rooted under `codriver.vendor.` — so
codriver can coexist on runtimepath with a real claudecode.nvim install. Codriver
exposes exactly one command namespace: the vendored `:ClaudeCode*` registrations
are intercepted and re-exported as `:Codriver*`, so an installed claudecode.nvim
keeps its own commands, shutdown augroup and health report untouched.

See [VENDOR.md](VENDOR.md). Never hand-edit anything under `vendor/`; re-sync with:

```sh
./scripts/vendor-sync.sh <upstream-sha>
```

## Development

The toolchain is provisioned by [mise](https://mise.jdx.dev), mirroring
upstream's pinned versions.

```sh
mise install       # provision luajit, neovim, stylua, treefmt, …
mise run setup     # build the Lua test rocks (busted/luacheck/luacov)
mise run all       # format + lint + typecheck + test
```

| Task                    | What it does                                                      |
| ----------------------- | ----------------------------------------------------------------- |
| `mise run test`         | busted units, then the headless-Neovim checks                     |
| `mise run test-nvim`    | every `tests/nvim/*_check.lua` in its own headless Neovim         |
| `mise run check`        | parses all Lua (vendor included), then luacheck (vendor excluded) |
| `mise run typecheck`    | lua-language-server over the wrapper modules (vendor excluded)    |
| `mise run format`       | treefmt — stylua, prettier, shfmt, shellcheck                     |
| `mise run format-check` | verify formatting without writing                                 |
| `mise run vendor-sync`  | re-vendor upstream at the pinned SHA                              |
| `mise run clean`        | remove generated coverage files                                   |

Tests are split deliberately: `tests/codriver/` are pure-Lua units run under
bare LuaJIT with a minimal `vim` stub, while anything needing a real Neovim API
goes in `tests/nvim/`. Each `*_check.lua` there runs in its own headless nvim
against the real server, with a sandboxed `CLAUDE_CONFIG_DIR` so no check can
touch a live session's lockfile. The stub in `tests/busted_setup.lua` is
intentionally tiny and must not grow into a general-purpose Neovim mock.

## Licence

MIT — see [LICENSE](LICENSE).

Vendored claudecode.nvim is MIT, © 2025 Coder Technologies Inc. Attribution and
the scope of the vendoring transform are in [NOTICE](NOTICE); upstream's licence
text is retained verbatim at `lua/codriver/vendor/LICENSE.claudecode`.
