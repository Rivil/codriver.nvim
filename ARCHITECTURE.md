# Architecture

This document describes what the system _does_, organized by feature — one entry
per user-facing capability, never one per phase and never one per module. Read it
top-to-bottom to learn the capabilities; follow the symbol links to find the code.

Every entry follows one fixed template:

### <Feature name — a user-facing capability, not a module or a phase>

<One line: what this capability does.>

- Symbol.Name — path/to/file.ext:line
- Another.Symbol — path/to/other.ext:line

_introduced <phase-id> · extended <phase-id> · <short-sha>_

Entries are maintained automatically: dross-ship merges each phase's landmarks
into the matching feature entry (updating in place), and /dross-architecture can
regenerate the whole document from a scan of the code and git history.

<!-- entries below, alphabetical by feature -->

### Coexistence with claudecode.nvim

Codriver loads alongside a real claudecode.nvim install without shadowing its
modules, commands, shutdown augroup or health report.

- claude_commands — tests/nvim/coexistence_check.lua:54

_introduced session-bringup · f641166_

### Command surface

The vendored ClaudeCode\* commands are re-exported under `:Codriver*` names, so
codriver owns exactly one namespace.

- commands.capture — lua/codriver/commands.lua:75
- as_registered — tests/nvim/command_surface_check.lua:97

_introduced session-bringup · 7cfaf6e_

### Headless check suite

Every `tests/nvim/*_check.lua` runs in its own headless nvim against the real
server, sandboxed so no check can touch a live session's lockfile.

- harness.setup — tests/nvim/harness.lua:236

_introduced session-bringup · a6d57dd_

### Option resolution

`setup(opts)` splits codriver's top-level options from nested claudecode ones,
rejects unknown top-level keys, and forces the vendored auto_start off.

- config.resolve — lua/codriver/config.lua:122

_introduced session-bringup · 9b71d26_

### Plugin setup

`require("codriver").setup()` resolves options, runs the vendored setup inside
the capture shim, and starts a session only when `auto_start` is opted in.

- M.setup — lua/codriver/init.lua:171

_introduced session-bringup · d8e2355_

### Session bring-up

Starting a session launches the Claude CLI already wired to this Neovim
instance, and Claude reads the unsaved buffer and live visual selection over
MCP without the user pasting anything.

- expect_launch_env — tests/nvim/terminal_env_check.lua:102
- call_tool — tests/nvim/mcp_context_check.lua:81

_introduced session-bringup · 25388d7_

### Session lifecycle

Start brings the server up before the terminal, a second start reports the live
session, and stop clears both the lockfile and the selection autocmds.

- session.ensure_server — lua/codriver/session.lua:50
- session_lifecycle_check — tests/nvim/session_lifecycle_check.lua:90

_introduced session-bringup · 74beea0_

### Session status

Listening and connected are reported as two distinguishable states — one line
from `:CodriverStatus`, three independently-failing lines from
`:checkhealth codriver`.

- status.describe — lua/codriver/status.lua:35
- health.check — lua/codriver/health.lua:131
- status_check — tests/nvim/status_check.lua:74

_introduced session-bringup · 4ec7d3c_

### Vendoring

`scripts/vendor-sync.sh` re-imports upstream claudecode.nvim at a pinned SHA,
applying the require-rewrite and health rename in-script rather than by hand.

- vendor-sync health rename step — scripts/vendor-sync.sh:114

_introduced session-bringup · 1c8b0fc_
