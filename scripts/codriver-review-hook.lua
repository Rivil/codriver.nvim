-- codriver's Claude Code Stop hook — ambient review on save. Registered by
-- session.lua's arm() as:
--
--   nvim --clean -l scripts/codriver-review-hook.lua
--
-- `--clean` means no user config, no runtimepath, no mise/luarocks on PATH —
-- this script is the only thing that runs, same as scripts/codriver-hook.lua.
--
-- Double-gated (c-4, c-5): this only RPCs into the live instance when the
-- state file says role=navigator and review_on_save=true, AND the
-- transcript's last assistant reply actually contains a REVIEW line (t-6) —
-- so an ordinary driver-mode reply, or a navigator reply with nothing to
-- say, never misrenders as a review. Every internal failure (unreadable
-- transcript, unparsable JSON, a dead RPC address, ...) fails closed into
-- "render nothing" rather than raising — a Stop hook has no stdout contract
-- to report through, unlike the PreToolUse hook's deny document.

local script = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local plugin_root = vim.fn.fnamemodify(script, ":p:h:h")
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

---Claude Code's Stop hook payload names the transcript file rather than
---inlining it.
---@return string|nil
local function read_transcript_path()
  local raw = io.read("*a") or ""
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded.transcript_path
end

---The last assistant-role message's text out of a Claude Code transcript
---JSONL file (one JSON object per line, `content` a string or a list of
---content blocks). Returns "" on anything unreadable or unparsable rather
---than raising: a malformed transcript must fail closed into "nothing to
---parse", never crash the hook.
---@param path string|nil
---@return string
local function last_assistant_text(path)
  if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
    return ""
  end

  local text = ""
  for _, line in ipairs(vim.fn.readfile(path)) do
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and type(decoded) == "table" and decoded.type == "assistant" then
      local content = (decoded.message or {}).content
      if type(content) == "string" then
        text = content
      elseif type(content) == "table" then
        local parts = {}
        for _, block in ipairs(content) do
          if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            table.insert(parts, block.text)
          end
        end
        if #parts > 0 then
          text = table.concat(parts, "\n")
        end
      end
    end
  end
  return text
end

---Fire-and-forget the parsed comments at the live Neovim instance over its
---RPC server address — the same shape as scripts/codriver-hook.lua's own
---notify(). Never blocks and never raises past this call.
---@param comments table
local function notify(comments)
  local address = os.getenv("CODRIVER_NVIM_ADDRESS")
  if type(address) ~= "string" or address == "" then
    return
  end
  local ok_chan, chan = pcall(vim.fn.sockconnect, "pipe", address, { rpc = true })
  if not ok_chan or type(chan) ~= "number" or chan == 0 then
    return
  end
  pcall(
    vim.rpcnotify,
    chan,
    "nvim_exec_lua",
    "require('codriver.review.notify').received(...)",
    { { comments = comments } }
  )
end

local probe = { live = false }
local ok_state, state = pcall(require, "codriver.hook.state")
if ok_state then
  local ok_probe, probed = pcall(state.probe, { CODRIVER_STATE_FILE = os.getenv("CODRIVER_STATE_FILE") })
  if ok_probe and type(probed) == "table" then
    probe = probed
  end
end

if probe.live and probe.role == "navigator" and probe.review_on_save == true then
  local ok_parse, parse = pcall(require, "codriver.review.parse")
  if ok_parse then
    local text = last_assistant_text(read_transcript_path())
    local ok_comments, comments = pcall(parse.parse, text)
    if ok_comments and type(comments) == "table" and #comments > 0 then
      notify(comments)
    end
  end
end

os.exit(0, true)
