require("tests.busted_setup")

local bash = require("codriver.hook.bash")

-- The matcher is pure string work with no vim.* surface, which is why it lives
-- in the busted lane rather than tests/nvim/. If it ever reaches for a vim API
-- the fix is to stop reaching, not to grow the stub.
--
-- Everything here rests on the `bash_policy` lock: c-2's byte-identity guarantee
-- cannot be delivered by out-parsing a shell, so this is an allowlist and the
-- default is refusal. Most of the deny assertions below therefore pass "for
-- free" — `eval` is refused because it was never listed, not because a rule
-- names it. They are still asserted one by one, because their value is catching
-- a future allowlist entry that quietly readmits them.
--
-- The refusal assertions are deliberately `is_falsy` rather than `is_false`: a
-- security matcher should not be failed over returning nil instead of false.
-- The positive assertions are what stop an empty stub passing this file.

local TEST_COMMAND = "mise run test"

---Every command in the list must be refused, asserted individually.
---@param commands string[]
---@param why string
local function all_refused(commands, why)
  for _, command in ipairs(commands) do
    assert.is_falsy(bash.allows(command, TEST_COMMAND), ("%q must be refused — %s"):format(command, why))
  end
end

---Every command in the list must be allowed, asserted individually.
---@param commands string[]
---@param why string
local function all_allowed(commands, why)
  for _, command in ipairs(commands) do
    assert.is_truthy(bash.allows(command, TEST_COMMAND), ("%q must be allowed — %s"):format(command, why))
  end
end

describe("codriver.hook.bash", function()
  describe("allows", function()
    it("refuses redirection even when the head token is allowlisted", function()
      -- A redirection turns a read into a write without changing the command
      -- that is being run, so inspecting the head token cannot catch it.
      all_refused({
        "echo hi > f",
        "grep x lua/ >> out",
        "cmd 2>f",
        "rg -n pat lua/ > out",
        "git status | tee status.txt",
        "tee f",
      }, "it redirects output, which writes regardless of what the head token is")
    end)

    it("refuses a chain unless every segment independently matches", function()
      all_refused({
        "git status && rm -rf lua",
        "git log; rm x",
        "rg -n pat lua/ | xargs rm",
      }, "a later segment writes, so matching only the head token would let it through")
    end)

    it("still allows a pipeline whose every segment matches", function()
      -- The inverse half, and the reason segmenting is not just a blanket
      -- refusal of every metacharacter: piping into a pager or a counter is
      -- ordinary read-only work and c-5 depends on it surviving.
      all_allowed({
        "git log | head -20",
        "rg -n pat lua/ | head",
        "git status --short | wc -l",
      }, "every segment is independently allowlisted")
    end)

    it("refuses command substitution regardless of head token", function()
      -- The substituted command runs. Whatever the outer command is, it is not
      -- the only thing being executed.
      all_refused({
        'grep "$(rm -f x)" .',
        "grep `rm -f x` .",
        "diff <(rm x) y",
        "ls $(rm x)",
      }, "the substituted command runs, so the outer head token is not what executes")
    end)

    it("refuses interpreters and write-forms individually", function()
      -- None of these are allowlisted, so each is refused by default. Asserted
      -- one at a time so that adding any of them later fails loudly here.
      all_refused({
        "eval rm x",
        'sh -c "rm x"',
        'bash -c "rm x"',
        "xargs rm",
        "env A=1 rm x",
        "nohup rm x",
        "python3 -c \"open('f','w')\"",
        "find . -delete",
        "find . -exec rm {} +",
        "sed -i s/a/b/ f",
        "perl -i -pe s/a/b/ f",
      }, "it can execute or rewrite something the head token does not name")
    end)

    it("matches git by subcommand rather than by head token", function()
      -- `git` is the one head token where the argument decides whether the
      -- command writes, so the head alone is not enough information.
      all_refused({
        "git commit -m x",
        "git checkout .",
        "git restore .",
        "git apply p.patch",
        "git stash",
        "git clean -fd",
        "git config --global user.name x",
      }, "the git subcommand writes to the tree, the index or the config")

      all_allowed({
        "git status",
        "git log",
        "git diff",
        "git show HEAD",
        "git blame lua/codriver/init.lua",
        "git ls-files",
        "git rev-parse HEAD",
      }, "the git subcommand only reads")
    end)

    it("allows the read-only working set", function()
      -- Asserted positively, not just as the complement of the deny set: a
      -- matcher that refuses everything satisfies every deny assertion above
      -- while making c-5's read-only work impossible.
      all_allowed({
        "rg -n pat lua/",
        "git status --short",
        "git log --oneline -5",
        "ls tests",
        "cat README.md",
      }, "this is the ordinary read-only work navigator mode has to keep")
    end)

    it("matches the configured test command whole, never as a prefix", function()
      -- The test command is a deliberate write-capable hole in an otherwise
      -- read-only allowlist. Prefix matching would widen it to anything sharing
      -- those leading tokens.
      assert.is_truthy(bash.allows("mise run test", TEST_COMMAND), "the configured test command must run")

      all_refused({
        "mise run format",
        "mise run test; rm x",
        "mise run test && rm x",
        "mise run testing",
      }, "it is not the configured test command, it merely starts with it")
    end)

    it("refuses head-token bypasses", function()
      all_refused({
        "FOO=1 rm x",
        "/bin/rm -rf .",
        "rgx --write f",
      }, "leading assignments, an absolute path, and a longer name must not smuggle a head token past the list")
    end)

    it("refuses an empty or whitespace-only command", function()
      -- An empty command reaching a fall-through allow is the worst possible
      -- default: it is what a malformed payload degrades into.
      all_refused({ "", "   ", "\t", "\n" }, "an empty command must refuse rather than fall through to allow")
    end)

    it("takes the test command per call rather than as a module constant", function()
      -- Driven with two different values in one spec run, which a module-level
      -- constant makes impossible. t-5 threads the value it read from the
      -- session record through to here, so the value that governs must be the
      -- one passed in.
      assert.is_truthy(bash.allows("mise run test", "mise run test"), "the supplied test command must match")
      assert.is_falsy(bash.allows("mise run test", "just check"), "a different test command must not match")
      assert.is_truthy(bash.allows("just check", "just check"), "the supplied test command must match")
    end)

    it("disables the test-command allowance entirely when it is nil", function()
      -- Not "allows everything" and not "raises": a session with no configured
      -- test command simply has no test-command hole. Raising here would take
      -- down the hook, and a hook that crashes is treated as allow.
      assert.has_no.errors(function()
        bash.allows("mise run test", nil)
      end)

      assert.is_falsy(bash.allows("mise run test", nil), "a nil test command must not allow the test command")
      assert.is_truthy(
        bash.allows("rg -n pat lua/", nil),
        "a nil test command disables only its own allowance, not the rest of the allowlist"
      )
    end)

    describe("bash_allow additions", function()
      it("allows a command whose head is only present in bash_allow.heads", function()
        local bash_allow = { heads = { "jq" } }

        assert.is_falsy(bash.allows("jq .", TEST_COMMAND), "jq is not a hardcoded default")
        assert.is_truthy(bash.allows("jq .", TEST_COMMAND, bash_allow), "bash_allow.heads must extend the allowlist")
      end)

      it("allows 'git <subcommand>' when the subcommand is only present in bash_allow.git_subcommands", function()
        local bash_allow = { git_subcommands = { "stash" } }

        assert.is_falsy(bash.allows("git stash", TEST_COMMAND), "stash is not a hardcoded default")
        assert.is_truthy(
          bash.allows("git stash", TEST_COMMAND, bash_allow),
          "bash_allow.git_subcommands must extend the allowlist"
        )
      end)

      it("still allows a hardcoded default when bash_allow omits it (additive, never replacing)", function()
        local bash_allow = { heads = { "jq" } }

        assert.is_truthy(
          bash.allows("git status", TEST_COMMAND, bash_allow),
          "bash_allow must add to the defaults, never replace them"
        )
      end)
    end)
  end)

  describe("effective_allowlist", function()
    it("returns defaults only when bash_allow is nil", function()
      local allowlist = bash.effective_allowlist(nil)

      assert.is_true(allowlist.heads.rg)
      assert.is_true(allowlist.git_subcommands.status)
      assert.is_nil(allowlist.heads.jq)
    end)

    it("merges hardcoded defaults with bash_allow additions", function()
      local allowlist = bash.effective_allowlist({ heads = { "jq" }, git_subcommands = { "stash" } })

      assert.is_true(allowlist.heads.rg, "hardcoded defaults survive the merge")
      assert.is_true(allowlist.heads.jq, "the addition is present")
      assert.is_true(allowlist.git_subcommands.status, "hardcoded defaults survive the merge")
      assert.is_true(allowlist.git_subcommands.stash, "the addition is present")
    end)
  end)
end)
