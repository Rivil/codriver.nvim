---@brief Default keymaps for `:CodriverSend` / `:CodriverSendText`.
---
--- Kept apart from codriver.config (resolving `opts.keys` into lhs strings)
--- and codriver.commands (re-exporting the vendored command surface): this
--- module's only job is turning a resolved `keys` table into `vim.keymap.set`
--- calls, so init.lua's setup() stays "resolve, register, apply" instead of
--- interleaving keymap logic with command registration.

local M = {}

---Wire the default Send/SendText keymaps from a resolved `keys` table.
---
---An absent entry (disabled via `opts.keys.<name> = false` in config.lua, or
---simply not present in `keys`) is not mapped at all — codriver never guesses
---at a fallback binding once a user has said no to the default one.
---@param keys table<string, string>|nil resolved.codriver.keys from config.lua
function M.apply(keys)
  keys = keys or {}

  if keys.send then
    -- Normal mode: <Cmd> runs :CodriverSend without a range, which is exactly
    -- what a bare `:CodriverSend` does — the current-buffer/tree-selection
    -- path in handle_send_normal.
    vim.keymap.set(
      "n",
      keys.send,
      "<Cmd>CodriverSend<CR>",
      { silent = true, desc = "Send current buffer to Claude Code as an at-mention" }
    )
    -- Visual mode: the plain `:` form, not <Cmd>. Leaving Visual mode via `:`
    -- is what makes Neovim insert the `'<,'>` range prefix itself, which is
    -- what gives handle_send_visual a range to work from.
    vim.keymap.set(
      "v",
      keys.send,
      ":CodriverSend<CR>",
      { silent = true, desc = "Send visual selection to Claude Code as an at-mention" }
    )
  end

  if keys.send_text then
    -- No <CR>: this prefills the command-line and waits, per the locked
    -- sendtext_ux decision — the bang/nargs semantics of :CodriverSendText
    -- stay visible and editable instead of hiding behind a prompt.
    vim.keymap.set("n", keys.send_text, ":CodriverSendText ", { desc = "Send ad-hoc text to Claude Code" })
  end
end

return M
