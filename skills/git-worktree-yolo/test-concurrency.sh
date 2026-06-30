#!/usr/bin/env bash
#
# test-concurrency.sh — proves atomic writes + the per-worktree lock: no half-written
# files, no temp leftovers, parallel same-target syncs stay correct, stale locks are
# stolen, and the lock is always released.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/git-worktree-yolo.sh"
SB="$(mktemp -d "${TMPDIR:-/tmp}/wtcc.XXXXXX")"; SB="$(cd "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # ignore any global hook

pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
ck(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

O="$SB/api-server"; WT="$SB/api-server-perf"
mkdir -p "$O"; git -C "$O" init -q; git -C "$O" config user.email s@t; git -C "$O" config user.name s
printf '/.env\n' > "$O/.gitignore"; echo x > "$O/f"; git -C "$O" add -A; git -C "$O" commit -qm init
# a sizeable .env that references the origin path (exercises rewrite-on-temp)
{ echo "SECRET=$O/x"; for i in $(seq 1 200); do echo "VAR$i=value$i"; done; } > "$O/.env"
EXPECT_LINES=$(wc -l < "$O/.env" | tr -d ' ')
git -C "$O" worktree add -q -b perf "$WT" >/dev/null 2>&1

LOCK="${TMPDIR:-/tmp}/git-worktree-yolo-$(printf '%s' "$WT" | tr '/ ' '__').lock"

echo "== 1. single sync: atomic result, no temp leftovers, lock released =="
bash "$SCRIPT" "$WT" >/dev/null 2>&1
ck ".env content correct (rewritten, complete)"  'grep -qF "SECRET=$WT/x" "$WT/.env"'
ck ".env not corrupted (line count matches)"     '[[ "$(wc -l < "$WT/.env" | tr -d " ")" == "$EXPECT_LINES" ]]'
ck "no .wty-tmp.* leftovers"                      '[[ -z "$(find "$WT" -name "*.wty-tmp.*" 2>/dev/null)" ]]'
ck "lock released after run"                      '[[ ! -d "$LOCK" ]]'
ck "git status clean"                             '[[ -z "$(git -C "$WT" status --porcelain)" ]]'

echo "== 2. 8 parallel syncs of the SAME worktree: no corruption, no leftovers =="
rm -f "$WT/.env"
pids=""
for n in $(seq 1 8); do bash "$SCRIPT" "$WT" >/dev/null 2>&1 & pids="$pids $!"; done
for p in $pids; do wait "$p" || true; done
ck "parallel: .env present & rewritten"          'grep -qF "SECRET=$WT/x" "$WT/.env"'
ck "parallel: .env not doubled/corrupted"        '[[ "$(wc -l < "$WT/.env" | tr -d " ")" == "$EXPECT_LINES" ]]'
ck "parallel: no origin path remains"            '! grep -qF "SECRET=$O/x" "$WT/.env"'
ck "parallel: no .wty-tmp.* leftovers"           '[[ -z "$(find "$WT" -name "*.wty-tmp.*" 2>/dev/null)" ]]'
ck "parallel: lock released"                     '[[ ! -d "$LOCK" ]]'
ck "parallel: git status clean"                  '[[ -z "$(git -C "$WT" status --porcelain)" ]]'

echo "== 3. a live lock makes a concurrent run SKIP (no work, no error) =="
mkdir -p "$LOCK"; echo $$ > "$LOCK/pid"   # held by THIS (live) process
rm -f "$WT/.env"
bash "$SCRIPT" "$WT" >/dev/null 2>&1; rc=$?
ck "skipped run exits 0 (benign)"                '[[ "$rc" -eq 0 ]]'
ck "skipped run did NOT sync (lock held)"        '[[ ! -f "$WT/.env" ]]'
rm -rf "$LOCK"

echo "== 4. a STALE lock (dead PID) is stolen and the sync proceeds =="
mkdir -p "$LOCK"; echo 999999 > "$LOCK/pid"    # PID that does not exist
bash "$SCRIPT" "$WT" >/dev/null 2>&1
ck "stale lock stolen → .env synced"             '[[ -f "$WT/.env" ]] && grep -qF "SECRET=$WT/x" "$WT/.env"'
ck "lock released after stealing"                '[[ ! -d "$LOCK" ]]'

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
