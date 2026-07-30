# codriver.nvim

Claude Code as a **navigator**, not an author.

You keep writing the code and holding the mental model. Claude sits beside you,
watches every line, and advises — and only writes when you explicitly hand over
the keyboard.

> **Status: scaffold.** The protocol layer is vendored and verified to load, and
> role state exists. Turn-taking enforcement, ambient review, and dross task
> binding are **not implemented yet**. There is nothing useful to install here
> yet.

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

## Architecture

The Claude Code IDE protocol (WebSocket server, lockfile discovery, MCP tools)
is **vendored** from [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim)
(MIT) rather than depended on, because role switching needs to reach internals
that upstream does not expose.

Vendored code lives under `lua/codriver/vendor/claudecode/` and is upstream-identical
except that every Lua module path is re-rooted under `codriver.vendor.` — so
codriver can coexist on runtimepath with a real claudecode.nvim install. See
[VENDOR.md](VENDOR.md). Never hand-edit anything under `vendor/`; re-sync with:

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

| Task                   | What it does                                                      |
| ---------------------- | ----------------------------------------------------------------- |
| `mise run test`        | busted units, then loads every vendored module in real Neovim     |
| `mise run test-nvim`   | just the headless-Neovim vendor smoke test                        |
| `mise run check`       | parses all Lua (vendor included), then luacheck (vendor excluded) |
| `mise run typecheck`   | lua-language-server over the wrapper modules (vendor excluded)    |
| `mise run format`      | treefmt — stylua, prettier, shfmt, shellcheck                     |
| `mise run vendor-sync` | re-vendor upstream at the pinned SHA                              |

Tests are split deliberately: `tests/codriver/` are pure-Lua units run under
bare LuaJIT with a minimal `vim` stub, while anything needing a real Neovim API
goes in `tests/nvim/`. The stub in `tests/busted_setup.lua` is intentionally
tiny and must not grow into a general-purpose Neovim mock.

## Licence

MIT — see [LICENSE](LICENSE).

Vendored claudecode.nvim is MIT, © 2025 Coder Technologies Inc. Attribution and
the scope of the vendoring transform are in [NOTICE](NOTICE); upstream's licence
text is retained verbatim at `lua/codriver/vendor/LICENSE.claudecode`.
