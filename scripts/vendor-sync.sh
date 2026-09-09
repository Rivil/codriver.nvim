#!/usr/bin/env bash
#
# vendor-sync.sh — re-vendor coder/claudecode.nvim into lua/codriver/vendor/claudecode/.
#
#   ./scripts/vendor-sync.sh              # re-sync at the SHA pinned in VENDOR.md
#   ./scripts/vendor-sync.sh <sha>        # sync to a new upstream SHA and re-pin
#
# Vendored files are upstream-identical except for one mechanical transform:
# every Lua *module path* that names `claudecode` is re-rooted under
# `codriver.vendor.`, so this plugin can coexist on runtimepath with a real
# claudecode.nvim install. Nothing else is edited — see VENDOR.md.
#
# The transform matches an exact set of module paths derived from the vendored
# file tree, never a loose `claudecode` substring. That is deliberate: upstream
# also has display strings ("claudecode.nvim" in health.lua) and autocmd/augroup
# names ("claudecode_diffs", "claudecode-neovim") that must survive untouched.
set -euo pipefail

UPSTREAM_URL="https://github.com/coder/claudecode.nvim.git"
VENDOR_PREFIX="codriver.vendor"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/lua/codriver/vendor/claudecode"
PIN_FILE="$REPO_ROOT/VENDOR.md"

die() {
  echo "vendor-sync: $*" >&2
  exit 1
}

# --- resolve the target SHA -------------------------------------------------
SHA="${1:-}"
if [ -z "$SHA" ]; then
  [ -f "$PIN_FILE" ] || die "no SHA given and $PIN_FILE does not exist"
  SHA="$(sed -n 's/^- upstream_sha: *`\([0-9a-f]\{40\}\)`.*/\1/p' "$PIN_FILE" | head -1)"
  [ -n "$SHA" ] || die "could not read upstream_sha from $PIN_FILE"
fi
case "$SHA" in
[0-9a-f]*) [ "${#SHA}" -eq 40 ] || die "SHA must be a full 40-char commit id, got: $SHA" ;;
*) die "SHA must be a full 40-char commit id, got: $SHA" ;;
esac

# --- fetch upstream at that exact commit ------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "vendor-sync: fetching $UPSTREAM_URL @ $SHA"
git init --quiet "$WORK/upstream"
git -C "$WORK/upstream" remote add origin "$UPSTREAM_URL"
git -C "$WORK/upstream" fetch --quiet --depth 1 origin "$SHA"
git -C "$WORK/upstream" checkout --quiet FETCH_HEAD

SRC="$WORK/upstream/lua/claudecode"
[ -d "$SRC" ] || die "upstream tree has no lua/claudecode/ at $SHA"

# --- copy in ----------------------------------------------------------------
rm -rf "$VENDOR_DIR"
mkdir -p "$(dirname "$VENDOR_DIR")"
cp -R "$SRC" "$VENDOR_DIR"

# --- derive the exact module-path set from the vendored tree ----------------
# lua/codriver/vendor/claudecode/server/tcp.lua  -> claudecode.server.tcp
# lua/codriver/vendor/claudecode/server/init.lua -> claudecode.server.init AND claudecode.server
# lua/codriver/vendor/claudecode/init.lua        -> claudecode.init AND claudecode
mods_file="$WORK/mods.txt"
: >"$mods_file"
while IFS= read -r f; do
  rel="${f#"$VENDOR_DIR"/}"
  rel="${rel%.lua}"
  dotted="claudecode.${rel//\//.}"
  echo "$dotted" >>"$mods_file"
  case "$dotted" in
  *.init) echo "${dotted%.init}" >>"$mods_file" ;;
  esac
done < <(find "$VENDOR_DIR" -type f -name '*.lua' | sort)

# `pcall(require, "claudecode.terminal." .. provider_name)` builds a module path
# from a trailing-dot prefix, so that prefix is a module path too.
echo "claudecode.terminal." >>"$mods_file"

sort -u "$mods_file" -o "$mods_file"
echo "vendor-sync: rewriting $(wc -l <"$mods_file" | tr -d ' ') module paths"

# --- apply the rewrite ------------------------------------------------------
# Exact quoted-string matches only. The closing quote anchors each pattern, so
# "claudecode.server" cannot swallow "claudecode.server.init".
# -print0/xargs -0 rather than $(find ...): the file list must survive paths
# containing spaces, and xargs re-runs perl per batch so BEGIN reads the module
# list again each time — which is fine, it is idempotent.
export MODS_FILE="$mods_file"
export VENDOR_PREFIX
find "$VENDOR_DIR" -type f -name '*.lua' -print0 | xargs -0 perl -i -pe '
  BEGIN {
    open(my $fh, "<", $ENV{MODS_FILE}) or die "cannot read module list: $!";
    my @mods = map { chomp; $_ } <$fh>;
    close $fh;
    my $alt = join "|", map { quotemeta } sort { length($b) <=> length($a) } @mods;
    $RE = qr/"($alt)"/;
    $PFX = $ENV{VENDOR_PREFIX};
  }
  s/$RE/"$PFX.$1"/g;
'

# --- verify -----------------------------------------------------------------
# Every module path must now be prefixed. Anything left quoting a bare
# claudecode module path means the rewrite missed a call site.
residual=0
while IFS= read -r mod; do
  if grep -rn --include='*.lua' -F "\"$mod\"" "$VENDOR_DIR" | grep -v "$VENDOR_PREFIX\.$mod" >/dev/null; then
    echo "vendor-sync: UNREWRITTEN module path \"$mod\":" >&2
    grep -rn --include='*.lua' -F "\"$mod\"" "$VENDOR_DIR" | grep -v "$VENDOR_PREFIX\.$mod" >&2
    residual=1
  fi
done <"$mods_file"
[ "$residual" -eq 0 ] || die "rewrite incomplete — refusing to leave a broken vendor tree"

# --- stop the vendored health check hijacking :checkhealth ------------------
# Neovim resolves `:checkhealth <name>` by globbing `lua/**/<name>/health.lua`,
# by *directory* name — so a file at lua/codriver/vendor/claudecode/health.lua
# makes installing codriver inject a section into a real claudecode.nvim's
# health report, and into bare `:checkhealth`. Renaming it is the fix.
#
# Deliberately after the rewrite: renaming first would drop `claudecode.health`
# out of the derived module set, so an upstream require of it added in a later
# release would slip through unrewritten and resolve to the *real*
# claudecode.nvim at runtime. This way it is rewritten first, and then the check
# below fails loudly.
VENDORED_HEALTH="$VENDOR_DIR/health.lua"
RENAMED_HEALTH="$VENDOR_DIR/health_vendored.lua"

if [ -f "$VENDORED_HEALTH" ]; then
  mv "$VENDORED_HEALTH" "$RENAMED_HEALTH"
  echo "vendor-sync: renamed health.lua -> health_vendored.lua (keeps :checkhealth claudecode upstream's)"
fi

[ ! -e "$VENDORED_HEALTH" ] || die "$VENDORED_HEALTH still exists — the checkhealth de-hijack did not happen"
[ -f "$RENAMED_HEALTH" ] || die "no $RENAMED_HEALTH — upstream may have moved or dropped health.lua; revisit this step"

if grep -rn --include='*.lua' -F \
  -e "\"$VENDOR_PREFIX.claudecode.health\"" \
  -e '"claudecode.health"' \
  "$VENDOR_DIR" >/dev/null; then
  grep -rn --include='*.lua' -F \
    -e "\"$VENDOR_PREFIX.claudecode.health\"" \
    -e '"claudecode.health"' \
    "$VENDOR_DIR" >&2
  die "something requires the health module, which this step has just renamed out from under it"
fi

# Sanity: the vendored tree must not require anything outside itself that we
# have not accounted for, and must still parse.
if command -v luajit >/dev/null 2>&1; then
  while IFS= read -r f; do
    luajit -e "assert(loadfile('$f'))" || die "syntax error in vendored file: $f"
  done < <(find "$VENDOR_DIR" -type f -name '*.lua')
  echo "vendor-sync: all vendored files parse under luajit"
else
  echo "vendor-sync: luajit not on PATH — skipped the parse check" >&2
fi

# --- re-pin -----------------------------------------------------------------
DATE="$(git -C "$WORK/upstream" show -s --format=%cs FETCH_HEAD)"
COUNT="$(find "$VENDOR_DIR" -type f -name '*.lua' | wc -l | tr -d ' ')"
cat >"$PIN_FILE" <<EOF
# Vendored upstream

\`lua/codriver/vendor/claudecode/\` is a vendored copy of
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) (MIT).

- upstream_sha: \`$SHA\`
- upstream_date: $DATE
- files: $COUNT Lua files
- synced_by: \`scripts/vendor-sync.sh\`

## The two modifications

Both are applied by the sync script, never by hand.

### 1. Module paths are re-rooted

Every Lua module path naming \`claudecode\` is re-rooted under
\`$VENDOR_PREFIX.\` — \`require("claudecode.server.tcp")\` becomes
\`require("$VENDOR_PREFIX.claudecode.server.tcp")\`. Without this, codriver.nvim
and a real claudecode.nvim install would both provide \`lua/claudecode/\` and
collide on runtimepath.

Display strings, augroup names and buffer-variable names (\`claudecode.nvim\`,
\`claudecode_diffs\`, \`claudecode-neovim\`) are **not** rewritten — they are not
module paths.

### 2. \`health.lua\` is renamed to \`health_vendored.lua\`

Neovim resolves \`:checkhealth <name>\` by globbing \`lua/**/<name>/health.lua\`,
matching on the _directory_ name. The vendored tree lives in a directory called
\`claudecode\`, so a file named \`health.lua\` inside it would put codriver's
vendored copy into a real claudecode.nvim's \`:checkhealth claudecode\` report —
and into bare \`:checkhealth\` — purely by being installed.

Nothing in the tree requires the module, so the rename costs nothing. Codriver's
own health check is \`:checkhealth codriver\` (\`lua/codriver/health.lua\`).

Nothing else differs from upstream. Do not hand-edit anything under
\`vendor/\`; change behaviour in wrapper modules instead, and re-sync with:

\`\`\`sh
./scripts/vendor-sync.sh <new-sha>
\`\`\`
EOF

echo "vendor-sync: vendored $COUNT files at $SHA ($DATE)"
echo "vendor-sync: re-pinned $PIN_FILE"
