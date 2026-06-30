#!/usr/bin/env bash
#
# test-advisory.sh — proves the "heads-up: can't auto-fix" advisories: JetBrains remote
# interpreter bound to origin, tracked files hardcoding the origin path, symlinks into origin.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/git-worktree-yolo.sh"
SB="$(mktemp -d "${TMPDIR:-/tmp}/wtadv.XXXXXX")"; SB="$(cd "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB"; unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL
git config --global user.email s@t; git config --global user.name s; git config --global init.defaultBranch main

pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
ck(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

O="$SB/api-server"; WT="$SB/api-server-perf"
mkdir -p "$O/config"; git -C "$O" init -q
# tracked file hardcoding the origin absolute path
printf 'root: %s/data\n' "$O" > "$O/config/paths.yml"
# tracked symlink pointing into the origin checkout
ln -s "$O/config" "$O/config-link"
echo x > "$O/app.rb"
git -C "$O" add -A; git -C "$O" commit -qm init

# a JetBrains remote interpreter bound to the ORIGIN path (global IDE state)
JB="$SB/Library/Application Support/JetBrains/RubyMine2026.1/options"
mkdir -p "$JB"
printf '<application><component name="ProjectJdkTable"><jdk><homePath value="docker-compose://[%s/docker-compose.local.yml]:api//usr/local/bin/ruby" /></jdk></component></application>\n' "$O" > "$JB/jdk.table.xml"

git -C "$O" worktree add -q -b perf "$WT" >/dev/null 2>&1

echo "== run sync, capture report =="
REPORT="$("$SCRIPT" "$WT" 2>&1 || true)"
printf '%s\n' "$REPORT" | sed 's/^/    | /'

ck "advisory header shown"                     'grep -q "heads-up" <<<"$REPORT"'
ck "flags JetBrains interpreter bound to origin" 'grep -qi "JetBrains remote interpreter" <<<"$REPORT"'
ck "flags tracked file hardcoding origin path"  'grep -q "config/paths.yml" <<<"$REPORT"'
ck "flags symlink into origin"                  'grep -qi "symlink" <<<"$REPORT"'

echo "== clean repo (no issues) shows NO heads-up =="
C="$SB/clean"; CW="$SB/clean-wt"; mkdir -p "$C"; git -C "$C" init -q
git -C "$C" config user.email s@t; git -C "$C" config user.name s
printf '/.env\n' > "$C/.gitignore"; echo x > "$C/f"; git -C "$C" add -A; git -C "$C" commit -qm i
echo "E=1" > "$C/.env"
git -C "$C" worktree add -q -b wt "$CW" >/dev/null 2>&1
# isolate from the JetBrains file created above
REPORT2="$(HOME="$SB/empty" "$SCRIPT" "$CW" 2>&1 || true)"
ck "no heads-up when nothing is wrong"          '! grep -q "heads-up" <<<"$REPORT2"'

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
