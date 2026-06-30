#!/usr/bin/env bash
#
# simulate.sh — proves git-worktree-yolo.sh end-to-end on a throwaway Rails-like repo.
# Builds origin repo with gitignored machine-local files, creates a worktree (which
# breaks), runs the sync, and asserts the worktree is fixed AND git stays clean.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/git-worktree-yolo.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/wtsim.XXXXXX")"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"   # canonicalize (macOS /var -> /private/var) to match git's report
trap 'rm -rf "$SANDBOX"' EXIT
ORIGIN="$SANDBOX/api-server"
WT="$SANDBOX/api-server-feature-123"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

echo "== 1. build origin repo (Rails-like) =="
mkdir -p "$ORIGIN"
git -C "$ORIGIN" init -q
git -C "$ORIGIN" config user.email sim@test.local
git -C "$ORIGIN" config user.name sim
mkdir -p "$ORIGIN/app" "$ORIGIN/config" "$ORIGIN/.idea" "$ORIGIN/log" "$ORIGIN/tmp" "$ORIGIN/node_modules/leftpad"
cat > "$ORIGIN/.gitignore" <<'G'
/.env
/log/
/tmp/
/coverage/
/node_modules/
/config/master.key
/.idea/workspace.xml
G
echo "puts 'app'"            > "$ORIGIN/app/main.rb"
echo "tracked"              > "$ORIGIN/config/application.rb"
echo '<module relative="$MODULE_DIR$/app"/>' > "$ORIGIN/.idea/api-server.iml"  # tracked, relative — must NOT change
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit -qm init

echo "== 2. create machine-local (gitignored) files in origin =="
# .env with a baked-in absolute origin path (the real-world breaker)
cat > "$ORIGIN/.env" <<E
DB_HOST=localhost
DB_NAME=spendit
SECRETS_PATH=$ORIGIN/config/secrets
ALT_DIR=$ORIGIN-feature-123/already_worktree_form
E
printf '\x01\x02\x03binary-secret\xff' > "$ORIGIN/config/master.key"     # binary -> verbatim
cat > "$ORIGIN/.idea/workspace.xml" <<X
<project>
  <property name="last_opened_file_path" value="$ORIGIN" />
</project>
X
# An IGNORED JetBrains module file — must NOT be synced (name-specific, auto-generated)
echo '<module/>' > "$ORIGIN/.idea/generated.iml"
printf '/.idea/generated.iml\n' >> "$ORIGIN/.gitignore"
git -C "$ORIGIN" add .gitignore && git -C "$ORIGIN" commit -qm "ignore generated.iml"
# heavy/regenerable — must be SKIPPED
dd if=/dev/zero of="$ORIGIN/log/development.log" bs=1024 count=200 2>/dev/null
echo "module.exports={}" > "$ORIGIN/node_modules/leftpad/index.js"
echo "cache"             > "$ORIGIN/tmp/cache.dump"

echo "== 3. create worktree (this is where breakage happens) =="
git -C "$ORIGIN" worktree add -q -b feature-123 "$WT"
check "worktree .env is MISSING after 'git worktree add'"        '[[ ! -f "$WT/.env" ]]'
check "worktree workspace.xml is MISSING"                        '[[ ! -f "$WT/.idea/workspace.xml" ]]'
check "worktree master.key is MISSING"                           '[[ ! -f "$WT/config/master.key" ]]'

echo "== 4. run git-worktree-yolo.sh against the worktree =="
bash "$SCRIPT" "$WT" >/dev/null

echo "== 5. assert the worktree is now fixed =="
check ".env synced into worktree"                                '[[ -f "$WT/.env" ]]'
check ".env path rewritten origin->worktree"                     'grep -qF "SECRETS_PATH=$WT/config/secrets" "$WT/.env"'
check ".env no longer references the ORIGINAL origin path"       '! grep -qF "SECRETS_PATH=$ORIGIN/config" "$WT/.env"'
check "boundary-safe: longer worktree-form path NOT corrupted"   'grep -qF "ALT_DIR=$ORIGIN-feature-123/already_worktree_form" "$WT/.env"'
check "workspace.xml synced"                                     '[[ -f "$WT/.idea/workspace.xml" ]]'
check "workspace.xml path rewritten to worktree"                 'grep -qF "value=\"$WT\"" "$WT/.idea/workspace.xml"'
check "master.key synced VERBATIM (binary, byte-identical)"      'cmp -s "$ORIGIN/config/master.key" "$WT/config/master.key"'

echo "== 6. assert heavy/regenerable dirs were SKIPPED =="
check "log/ NOT copied"                                          '[[ ! -e "$WT/log/development.log" ]]'
check "node_modules/ NOT copied"                                 '[[ ! -e "$WT/node_modules" ]]'
check "tmp/ NOT copied"                                          '[[ ! -e "$WT/tmp/cache.dump" ]]'

echo "== 7. assert ZERO git diff (the core safety invariant) =="
check "origin git status clean"   '[[ -z "$(git -C "$ORIGIN" status --porcelain)" ]]'
check "worktree git status clean" '[[ -z "$(git -C "$WT" status --porcelain)" ]]'
check "tracked relative .iml untouched" 'grep -qF "MODULE_DIR" "$WT/.idea/api-server.iml"'
check "ignored *.iml NOT synced (auto-managed, name-specific)" '[[ ! -e "$WT/.idea/generated.iml" ]]'

echo "== 8. idempotency: second run is a no-op, still clean =="
bash "$SCRIPT" "$WT" >/dev/null
check "re-run leaves worktree git status clean" '[[ -z "$(git -C "$WT" status --porcelain)" ]]'

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
