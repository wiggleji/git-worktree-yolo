#!/usr/bin/env bash
#
# test-secret-guard.sh — proves the "never commit secrets" harness: audit,
# pre-commit blocking, allow-list, and global guard install/uninstall. Isolated HOME.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/git-worktree-yolo.sh"
SB="$(mktemp -d "${TMPDIR:-/tmp}/wtsec.XXXXXX")"; SB="$(cd "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB"; unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL
git config --global user.email s@t; git config --global user.name s; git config --global init.defaultBranch main

pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
ck(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }
newrepo(){ local r="$1"; mkdir -p "$r"; git -C "$r" init -q; echo x>"$r/f"; git -C "$r" add -A; git -C "$r" commit -qm init; }

echo "== 1. audit flags a TRACKED secret (already committed) =="
R="$SB/tracked"; newrepo "$R"
echo "SECRET=1" > "$R/.env"; git -C "$R" add -f .env; git -C "$R" commit -qm "oops env"
rc=0; OUT="$("$SCRIPT" --audit "$R" 2>&1)" || rc=$?
ck "audit exits nonzero on tracked secret"   '[[ "$rc" -ne 0 ]]'
ck "audit names it TRACKED"                  'grep -q "TRACKED" <<<"$OUT"'

echo "== 2. audit warns on a NOT-gitignored (untracked) secret =="
R="$SB/atrisk"; newrepo "$R"; echo "K=1" > "$R/.env"   # not ignored, not tracked
rc=0; OUT="$("$SCRIPT" --audit "$R" 2>&1)" || rc=$?
ck "audit passes (nothing committed yet)"    '[[ "$rc" -eq 0 ]]'
ck "audit warns NOT gitignored"              'grep -q "NOT gitignored" <<<"$OUT"'

echo "== 3. audit clean when .env is gitignored; .env.example is fine =="
R="$SB/clean"; newrepo "$R"
printf '/.env\n' > "$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -qm ignore
echo "REAL=1" > "$R/.env"                     # gitignored
echo "TEMPLATE=" > "$R/.env.example"; git -C "$R" add .env.example; git -C "$R" commit -qm example
rc=0; OUT="$("$SCRIPT" --audit "$R" 2>&1)" || rc=$?
ck "audit clean"                             '[[ "$rc" -eq 0 ]]'
ck ".env.example NOT flagged"                '! grep -q "env.example" <<<"$OUT"'

echo "== 4. pre-commit guard BLOCKS staging a secret =="
R="$SB/precommit"; newrepo "$R"; printf '/.env\n' > "$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -qm i
echo "S=1" > "$R/.env"; git -C "$R" add -f .env
rc=0; OUT="$(cd "$R" && "$SCRIPT" --pre-commit-guard 2>&1)" || rc=$?
ck "guard blocks (exit 1)"                   '[[ "$rc" -eq 1 ]]'
ck "guard says COMMIT BLOCKED"               'grep -q "COMMIT BLOCKED" <<<"$OUT"'

echo "== 5. pre-commit guard ALLOWS example + normal files =="
R="$SB/allowok"; newrepo "$R"
echo "T=" > "$R/.env.example"; echo "code" > "$R/main.rb"; git -C "$R" add .env.example main.rb
rc=0; (cd "$R" && "$SCRIPT" --pre-commit-guard >/dev/null 2>&1) || rc=$?
ck "guard allows example + source (exit 0)"  '[[ "$rc" -eq 0 ]]'

echo "== 6. .worktree-yolo 'allow' overrides the guard =="
R="$SB/allowcfg"; newrepo "$R"; printf '/.env\n' > "$R/.gitignore"
printf 'allow .env\n' > "$R/.worktree-yolo"; git -C "$R" add .gitignore .worktree-yolo; git -C "$R" commit -qm i
echo "S=1" > "$R/.env"; git -C "$R" add -f .env
rc=0; (cd "$R" && "$SCRIPT" --pre-commit-guard >/dev/null 2>&1) || rc=$?
ck "allow-listed .env not blocked (exit 0)"  '[[ "$rc" -eq 0 ]]'

echo "== 7. --install-guard wires a real pre-commit that blocks a commit =="
"$SCRIPT" --install-guard >/dev/null 2>&1
ck "global pre-commit hook installed"        '[[ -x "$SB/.config/git/hooks/pre-commit" ]]'
R="$SB/realcommit"; newrepo "$R"; printf '/.env\n' > "$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -qm i
echo "S=1" > "$R/.env"; git -C "$R" add -f .env
rc=0; (cd "$R" && git commit -qm "try commit env" 2>/dev/null) || rc=$?
ck "real 'git commit' is blocked by the guard" '[[ "$rc" -ne 0 ]]'
ck "the secret did NOT get committed"           '! git -C "$R" log --all --name-only --pretty=format: | grep -qx ".env"'

echo "== 8. --uninstall-guard cleans up =="
"$SCRIPT" --uninstall-guard >/dev/null 2>&1
ck "pre-commit removed"                       '[[ ! -e "$SB/.config/git/hooks/pre-commit" ]]'
ck "core.hooksPath unset"                     '[[ -z "$(git config --global core.hooksPath || true)" ]]'

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
