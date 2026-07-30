-- Luacheck configuration for codriver.nvim
-- Based on coder/claudecode.nvim's .luacheckrc (see VENDOR.md).

-- Set global variable names
globals = {
	"vim",
	"expect",
	"assert_contains",
	"assert_not_contains",
	"spy", -- For luassert.spy and spy.any
}

-- Ignore warnings for unused self parameters
self = false

-- Allow trailing whitespace
ignore = {
	"212/self", -- Unused argument 'self'
	"631", -- Line contains trailing whitespace
}

-- Set max line length
max_line_length = 120

-- Allow using external modules
allow_defined_top = true
allow_defined = true

-- Enable more checking
std = "luajit+busted"

exclude_files = {
	"tests/mocks",
	-- Vendored upstream code. It is upstream's to lint, and the require-rewrite
	-- in scripts/vendor-sync.sh pushes some lines past max_line_length. Never
	-- hand-edited here, so linting it would only produce noise we cannot fix
	-- without breaking the vendor invariant.
	"lua/codriver/vendor",
}
