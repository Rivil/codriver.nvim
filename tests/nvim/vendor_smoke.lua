-- Vendor smoke test — run under real Neovim:
--
--   nvim --clean --headless -l tests/nvim/vendor_smoke.lua
--
-- scripts/vendor-sync.sh rewrites every `claudecode` module path to sit under
-- `codriver.vendor.`. It checks that the files still *parse*, but parsing does
-- not resolve a single require. A rewrite that missed a call site — or invented
-- a module that does not exist — only fails when something actually loads it.
--
-- So this walks the vendored tree, requires every module through Neovim's real
-- Lua loader, and fails on the first one that does not resolve. This is the
-- test that would have caught the `pcall(require, "claudecode.terminal." .. x)`
-- dynamic prefix if the rewrite had missed it.

local script = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fn.fnamemodify(script, ":p:h:h:h")
vim.opt.runtimepath:prepend(repo_root)

local vendor_root = repo_root .. "/lua/codriver/vendor/claudecode"

local failures = {}
local checked = 0

---Turn a vendored file path into the module name it should be requirable as.
---@param path string
---@return string
local function module_name(path)
  local rel = path:sub(#vendor_root + 2):gsub("%.lua$", "")
  local mod = "codriver.vendor.claudecode." .. rel:gsub("/", ".")
  return (mod:gsub("%.init$", ""))
end

local files = vim.fn.globpath(vendor_root, "**/*.lua", false, true)
table.sort(files)

if #files == 0 then
  io.stderr:write(("vendor_smoke: no vendored files found under %s\n"):format(vendor_root))
  vim.cmd("cquit 1")
end

for _, path in ipairs(files) do
  local mod = module_name(path)
  local ok, err = pcall(require, mod)
  checked = checked + 1
  if not ok then
    table.insert(failures, ("  %s\n    %s"):format(mod, tostring(err):gsub("\n", "\n    ")))
  end
end

-- The rewrite is only correct if nothing still reaches for the old namespace.
-- A module that quietly fell back to a globally-installed claudecode.nvim would
-- load fine above and hide the collision this whole layout exists to prevent.
for name in pairs(package.loaded) do
  if name == "claudecode" or name:match("^claudecode%.") then
    table.insert(failures, ("  leaked into the bare `claudecode` namespace: %s"):format(name))
  end
end

if #failures > 0 then
  io.stderr:write(
    ("vendor_smoke: %d/%d modules failed:\n%s\n"):format(#failures, checked, table.concat(failures, "\n"))
  )
  vim.cmd("cquit 1")
end

-- The wrapper must sit on top of the vendored layer without either shadowing
-- the other.
local codriver_ok, codriver = pcall(require, "codriver")
if not codriver_ok then
  io.stderr:write(('vendor_smoke: require("codriver") failed: %s\n'):format(codriver))
  vim.cmd("cquit 1")
end

local version_ok, version = pcall(codriver.get_version)
if not version_ok then
  io.stderr:write(("vendor_smoke: codriver.get_version() failed: %s\n"):format(version))
  vim.cmd("cquit 1")
end

print(
  ("vendor_smoke: %d vendored modules loaded; codriver %s wrapping claudecode %s"):format(
    checked,
    version.codriver,
    version.claudecode
  )
)
