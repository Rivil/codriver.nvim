-- Minimal Neovim init for headless test runs.
--
-- Puts the repo itself on runtimepath and nothing else, so a test sees exactly
-- what a user gets from a plugin manager: lua/, plugin/, and no other plugins
-- to borrow behaviour from.

local repo_root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")

-- packpath is deliberately left alone. Clearing it for "isolation" also hides
-- Neovim's own bundled packages, which makes netrw fail to load and produces an
-- E919 that looks like our problem but is not. `--clean` already keeps the
-- user's own packages out.
vim.opt.runtimepath:prepend(repo_root)
vim.opt.swapfile = false

return { repo_root = repo_root }
