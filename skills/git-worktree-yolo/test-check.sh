#!/usr/bin/env bash
#
# test-check.sh — proves the --check CI gate: tracked-secret and not-gitignored-secret
# FAILs, .gitignore/home-path WARNs, --strict promotion, --json output, and exit codes.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/git-worktree-yolo.sh"
SB="$(mktemp -d "${TMPDIR:-/tmp}/wtck.XXXXXX")"; SB="$(cd "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
ck(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }
newrepo(){ local r="$1"; mkdir -p "$r"; git -C "$r" init -q; git -C "$r" config user.email s@t; git -C "$r" config user.name s; }
run(){ rc=0; OUT="$("$SCRIPT" --check "$@" 2>&1)" || rc=$?; }   # sets OUT + rc

echo "== 1. clean repo (.env gitignored) → PASS, exit 0 =="
R="$SB/clean"; newrepo "$R"
printf '/.env\n/.env.local\n' > "$R/.gitignore"; echo x > "$R/app.rb"
git -C "$R" add -A; git -C "$R" commit -qm init; echo "E=1" > "$R/.env"
run "$R"
ck "clean repo exits 0"            '[[ "$rc" -eq 0 ]]'
ck "clean repo reports ready"      'grep -q "ready" <<<"$OUT"'

echo "== 2. tracked secret → FAIL, exit 1 =="
R="$SB/tracked"; newrepo "$R"
echo "SECRET=1" > "$R/.env"; git -C "$R" add -f .env; git -C "$R" commit -qm oops
run "$R"
ck "tracked secret exits 1"        '[[ "$rc" -eq 1 ]]'
ck "names the tracked secret"      'grep -q "secret is tracked by git" <<<"$OUT"'

echo "== 3. secret in tree, NOT gitignored → FAIL, exit 1 =="
R="$SB/untracked"; newrepo "$R"; echo x > "$R/app.rb"; git -C "$R" add -A; git -C "$R" commit -qm i
echo "K=1" > "$R/.env"    # not tracked, not ignored
run "$R"
ck "committable secret exits 1"    '[[ "$rc" -eq 1 ]]'
ck "warns about add -A staging"    'grep -q "git add -A" <<<"$OUT"'

echo "== 4. .env.example tracked is fine =="
R="$SB/example"; newrepo "$R"
printf '/.env\n/.env.local\n' > "$R/.gitignore"
echo "T=" > "$R/.env.example"; git -C "$R" add -A; git -C "$R" commit -qm i
run "$R"
ck ".env.example not flagged, exit 0" '[[ "$rc" -eq 0 ]]'

echo "== 5. missing .gitignore coverage → WARN (exit 0), --strict → FAIL (exit 1) =="
R="$SB/warn"; newrepo "$R"; echo x > "$R/app.rb"; git -C "$R" add -A; git -C "$R" commit -qm i
run "$R"
ck "warn-only exits 0"             '[[ "$rc" -eq 0 ]]'
ck "warns about .env gitignore"    'grep -q "does not cover" <<<"$OUT"'
run --strict "$R"
ck "--strict promotes to exit 1"   '[[ "$rc" -eq 1 ]]'

echo "== 6. tracked file with an absolute /Users path → WARN =="
R="$SB/abspath"; newrepo "$R"
printf '/.env\n/.env.local\n' > "$R/.gitignore"
printf 'root: /Users/dev/app/data\n' > "$R/config.yml"
git -C "$R" add -A; git -C "$R" commit -qm i
run "$R"
ck "warns about hardcoded home path" 'grep -q "hardcodes an absolute home path" <<<"$OUT"'

echo "== 7. --json output =="
R="$SB/json"; newrepo "$R"; echo "S=1" > "$R/.env"; git -C "$R" add -f .env; git -C "$R" commit -qm oops
rc=0; JOUT="$("$SCRIPT" --check --json "$R" 2>/dev/null)" || rc=$?
ck "--json exit 1 on failure"      '[[ "$rc" -eq 1 ]]'
ck "--json has ok:false"           'grep -q "\"ok\":false" <<<"$JOUT"'
ck "--json lists the failure"      'grep -q "secret is tracked" <<<"$JOUT"'

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
