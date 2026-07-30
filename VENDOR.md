# Vendored upstream

`lua/codriver/vendor/claudecode/` is a vendored copy of
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) (MIT).

- upstream_sha: `2390c6e45c4789072c293ac69de051d169668b29`
- upstream_date: 2026-06-25
- files: 38 Lua files
- synced_by: `scripts/vendor-sync.sh`

## The one modification

Every Lua module path naming `claudecode` is re-rooted under
`codriver.vendor.` — `require("claudecode.server.tcp")` becomes
`require("codriver.vendor.claudecode.server.tcp")`. Without this, codriver.nvim
and a real claudecode.nvim install would both provide `lua/claudecode/` and
collide on runtimepath.

Display strings, augroup names and buffer-variable names (`claudecode.nvim`,
`claudecode_diffs`, `claudecode-neovim`) are **not** rewritten — they are not
module paths.

Nothing else differs from upstream. Do not hand-edit anything under
`vendor/`; change behaviour in wrapper modules instead, and re-sync with:

```sh
./scripts/vendor-sync.sh <new-sha>
```
